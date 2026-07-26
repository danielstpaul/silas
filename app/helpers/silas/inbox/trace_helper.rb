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
      # at the signal until a person clears it.
      UI_LABEL = { "waiting" => "held", "completed" => "clear" }.freeze

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
        Silas::Engine.routes.url_helpers.public_send(helper, *args, script_name: Silas::Inbox.mount_path)
      end
    end
  end
end
