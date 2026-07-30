module Silas
  module Inbox
    module TraceHelper
      # The seven run states, in aspect (direction "Signals"): running is the
      # only aspect that pulses, in_doubt gets its own violet (it is neither
      # waiting-by-design nor failed), and canceled is a lamp going OUT —
      # dashed quiet, never red. Failed keeps the only red.
      STATUS_CLASS = {
        "queued" => "pill-grey", "running" => "pill-blue pill-pulse",
        "waiting" => "pill-amber", "in_doubt" => "pill-violet",
        "completed" => "pill-green", "failed" => "pill-red", "canceled" => "pill-quiet",
        # tool-invocation statuses map onto the same seven
        "pending" => "pill-grey", "started" => "pill-blue", "declined" => "pill-red",
        "approved" => "pill-green", "answered" => "pill-green",
        "required" => "pill-amber", "expired" => "pill-quiet"
      }.freeze

      # UI-only relabels — the database strings and the JSON API are untouched
      # (an operator who reads "held" here and greps the API will find
      # `waiting`; docs name both). Safety-system vocabulary: a turn is held
      # at the signal until a person clears it. `running` reads WORKING so the
      # pill and the rail's Working group say the same word about the same
      # turn; the disclosure on every tool row prints the raw enum.
      UI_LABEL = { "waiting" => "held", "running" => "working", "completed" => "clear" }.freeze

      def status_label(status)
        UI_LABEL[status.to_s] || status.to_s.tr("_", " ")
      end

      def status_pill(status)
        tag.span(status_label(status), class: "pill #{STATUS_CLASS[status.to_s] || 'pill-grey'}")
      end

      def step_text(step)
        Array(step.response_blocks).select { |b| b["type"] == "text" }.map { |b| b["text"] }.join.presence
      end

      # The final_answer payload, when the agent declared a schema.
      def step_structured(step)
        Array(step.response_blocks).reverse.find { |b| b["type"] == "structured" }&.dig("data")
      end

      def pretty_args(hash)
        JSON.pretty_generate(hash || {})
      end

      def cost_label(cost)
        tokens = "#{number_with_delimiter(cost[:input_tokens])} in / #{number_with_delimiter(cost[:output_tokens])} out"
        money = Silas::Inbox::Cost.format(cost[:microcents])
        if cost[:unpriced] || money.nil?
          "#{tokens} · cost unavailable"
        else
          "#{tokens} · #{money}"
        end
      end

      # ---- the feed ----------------------------------------------------
      #
      # One invocation, one sentence: what ran, on what, how it ended.
      #
      #   issue_refund · order #4821 · GBP 64.00 → held for approval
      #   issue_refund · order #4821 · GBP 64.00 → approved by Dana · refunded
      #
      # Everything these return is PLAIN TEXT. Arguments and results are
      # model-authored, so they reach the page only through ERB's escape —
      # nothing here may be marked html_safe.

      # A verdict outranks the status it wrote: `decline!` sets status=failed,
      # but a person refusing is not a crash and must not read like one.
      INVOCATION_STATE = {
        "pending" => "working", "started" => "working", "completed" => "clear",
        "failed" => "failed", "in_doubt" => "in_doubt"
      }.freeze

      STATE_ASPECT = {
        "held" => "amber", "working" => "blue", "clear" => "green", "failed" => "red",
        "declined" => "red", "expired" => "quiet", "in_doubt" => "violet"
      }.freeze

      # The states are settled quietly ONLY here; every other state either
      # needs a person or lost one.
      SETTLED_QUIETLY = %w[clear working].freeze

      MONEY_KEYS = %w[amount total price subtotal].freeze
      CURRENCY_KEYS = %w[currency currency_code].freeze

      def invocation_state(invocation)
        return "held" if invocation.awaiting_approval?
        return invocation.approval_state if %w[declined expired].include?(invocation.approval_state)

        INVOCATION_STATE.fetch(invocation.status, invocation.status)
      end

      def invocation_state_class(invocation)
        "deed-#{STATE_ASPECT.fetch(invocation_state(invocation), 'quiet')}"
      end

      # Salience. A read that worked is furniture; a tool that moved money or
      # sent a message is not, and neither is anything a person still owes a
      # verdict on. A FAILED read is loud too — having no effect doesn't make
      # a failure quiet. `idempotent` is the mode a tool declares when it only
      # reads; `transactional` is the one whose write and ledger row commit
      # together, and it gets the heaviest rule on the page.
      def invocation_weight(invocation)
        return "deed-exact" if invocation.effect_mode == "transactional"
        return "deed-loud" unless SETTLED_QUIETLY.include?(invocation_state(invocation))

        invocation.effect_mode == "idempotent" ? "deed-quiet" : "deed-loud"
      end

      def invocation_outcome(invocation)
        state = invocation_state(invocation)
        case state
        when "held"     then invocation.question? ? "held for an answer" : "held for approval"
        when "working"  then "working"
        when "in_doubt" then "in doubt — nobody knows whether it ran"
        when "declined" then declined_phrase(invocation)
        when "expired"  then invocation.question? ? "expired — nobody answered" : "expired — nobody cleared it"
        else [ verdict_phrase(invocation), result_or_failure_phrase(invocation, state) ].compact.join(" · ")
        end
      end

      # The middle of the sentence: enough of the call to recognise the job
      # without opening anything. Non-scalars are left out — a nested hash
      # flattened onto one line is noise — and wait in the disclosure.
      def invocation_arg_phrases(invocation, limit: 3)
        args = invocation.arguments
        return [] unless args.is_a?(Hash) && args.any?

        merged, phrases = money_phrase(args)
        args.each do |key, value|
          break if phrases.size >= limit
          next if merged.include?(key.to_s) || !scalar_arg?(value)

          phrases << arg_phrase(key.to_s, value)
        end
        phrases
      end

      # "GBP 64.00" is what an operator scans a refund line for; as two
      # separate phrases the currency and the number sit apart and neither
      # reads as money. Returns [keys consumed, phrases].
      def money_phrase(args)
        currency = args.find { |k, v| CURRENCY_KEYS.include?(k.to_s) && v.to_s.match?(/\A[A-Za-z]{3}\z/) }
        amount = args.find { |k, v| MONEY_KEYS.include?(k.to_s) && v.is_a?(Numeric) }
        return [ [], [] ] unless currency && amount

        [ [ currency[0].to_s, amount[0].to_s ], [ format("%s %.2f", currency[1].to_s.upcase, amount[1]) ] ]
      end

      # `order_id: 4821` reads as "order #4821". A bare flag reads as itself:
      # "dry run" beats "dry run true", and "no dry run" beats "dry run false".
      def arg_phrase(key, value)
        return "#{key.delete_suffix("_id").tr("_", " ")} ##{value}" if key.end_with?("_id")

        label = key.tr("_", " ")
        return label if value == true
        return "no #{label}" if value == false

        "#{label} #{value.to_s.truncate(48)}"
      end

      # What came back. A tool that returned nothing SAYS so — the absence is
      # a fact about the run, not a gap in the sentence.
      def invocation_result_phrase(invocation)
        result = invocation.result
        return "returned nothing" if result.nil? || result == {} || result == ""
        return result.to_s.truncate(48) unless result.is_a?(Hash)

        key, value = result.find { |_k, v| scalar_arg?(v) }
        key ? arg_phrase(key.to_s, value) : "#{result.size} #{"field".pluralize(result.size)} returned"
      end

      # Where the turn stands, in the words the pill has no room for. Never
      # says "waiting": the enum is `waiting`, the operator's word is HELD.
      def turn_progress(turn)
        case turn.status
        when "queued"    then "queued for a worker"
        when "running"   then "working now"
        when "waiting"   then "held — a person is needed"
        when "in_doubt"  then "in doubt — a tool crashed mid-call"
        when "canceled"  then "stopped before it finished"
        when "failed"    then turn.failure_reason.present? ? "failed — #{turn.failure_reason}" : "failed"
        when "completed" then turn.finished_at ? "answered #{silas_relative_time(turn.finished_at)}" : "answered"
        else status_label(turn.status)
        end
      end

      # A settled turn's one-line audit: how much ran, and how much of it
      # wrote. Reads off the loaded steps so the session page adds no queries.
      def turn_effects_summary(turn)
        invocations = turn.steps.flat_map(&:tool_invocations)
        return "no tools ran — answered directly" if invocations.empty?

        wrote = invocations.count { |i| i.effect_mode != "idempotent" && i.status == "completed" }
        "#{pluralize(invocations.size, "tool")} · #{wrote.zero? ? "nothing written" : "#{wrote} wrote"}"
      end

      # ---- lineage -----------------------------------------------------
      #
      # A handoff or a delegation starts a SECOND session. Nothing on the child
      # points back at the call that made it — the only link is the invocation
      # result — so the feed recovers the pair from there, and the child's
      # metadata says which of the two it was.

      LINEAGE_FROM = { "handoff" => "handed over by", "delegation" => "delegated by" }.freeze
      LINEAGE_TO   = { "handoff" => "handed to", "delegation" => "delegated to" }.freeze

      def lineage_relation(child)
        meta = child.metadata
        return nil unless meta.is_a?(Hash)
        return "handoff" if meta.key?("handoff_from")

        "delegation" if meta.key?("delegated_from")
      end

      def lineage_from_phrase(child) = LINEAGE_FROM.fetch(lineage_relation(child), "started by")
      def lineage_to_phrase(child)   = LINEAGE_TO.fetch(lineage_relation(child), "started")

      def invocation_child_session(invocation)
        result = invocation.result
        return nil unless result.is_a?(Hash) && result["session_id"].present?

        child = Silas::Session.find_by(id: result["session_id"])
        # Any tool may return a key called `session_id` meaning something of its
        # own. Only a session whose parent IS this call's session was started
        # by this call.
        child if child && child.parent_session_id == invocation.turn.session_id
      end

      # Children the feed has no place for. An at_most_once handoff that
      # crashes after Session.create! records no result, so the call that made
      # the child names nothing — without this the child is visible only from
      # the index, which is the orphan the lineage work exists to end.
      def stranded_child_sessions(session, turns)
        placed = turns.flat_map(&:steps).flat_map(&:tool_invocations).filter_map do |i|
          i.result["session_id"].to_i if i.result.is_a?(Hash) && i.result["session_id"].present?
        end
        session.child_sessions.reject { |child| placed.include?(child.id) }
      end

      # The turn a session is judged by: the one in flight, else the last one
      # to settle. Reads off the loaded association — the index depends on that.
      def session_state_turn(session)
        session.turns.detect(&:active?) || session.turns.last
      end

      def scalar_arg?(value)
        case value
        when String then value.present?
        when Numeric, true, false then true
        else false
        end
      end

      def verdict_phrase(invocation)
        case invocation.approval_state
        when "approved"
          invocation.approved_by.present? ? "approved by #{invocation.approved_by}" : "auto-approved by policy"
        when "answered"
          invocation.approved_by.present? ? "answered by #{invocation.approved_by}" : "answered"
        end
      end

      def declined_phrase(invocation)
        who = invocation.approved_by.present? ? "declined by #{invocation.approved_by}" : "declined"
        invocation.decline_reason.present? ? "#{who} — “#{invocation.decline_reason}”" : who
      end

      def result_or_failure_phrase(invocation, state)
        return "failed — #{invocation.error.to_s.lines.first.to_s.strip.truncate(72).presence || "no reason recorded"}" if state == "failed"
        return nil if invocation.approval_state == "answered" # the answer IS the result

        invocation_result_phrase(invocation)
      end

      # Prefixed: this helper is registered host-wide (broadcast renders need
      # it), and "relative_time" is exactly the name a host app would define.
      def silas_relative_time(time)
        return "" unless time

        "#{time_ago_in_words(time)} ago"
      end

      # Engine paths that resolve in EVERY render context. The mounted proxy
      # (`silas.`) leans on the rendering scope's url_options, which Turbo's
      # bare broadcast renderer doesn't have — so broadcast-rendered partials
      # build paths from the engine's own route set + the discovered mount.
      def silas_engine_path(helper, *args)
        helpers = Silas::Engine.routes.url_helpers
        # Rails 8.1's lazy route set: in a worker's FIRST broadcast render the
        # engine's helper module can predate its route draw, and the lazy
        # method_missing only retries when the app routes were *just* loaded —
        # otherwise it raises NoMethodError and the Turbo job dies silently
        # (observed: the first turn broadcast of a fresh worker). Force the
        # draw once on miss; every later call takes the fast path.
        Rails.application.reload_routes! unless helpers.respond_to?(helper)
        helpers.public_send(helper, *args, script_name: Silas::Inbox.mount_path)
      end
    end
  end
end
