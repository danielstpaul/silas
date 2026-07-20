module Silas
  # Terminal REPL for talking to the app's agent: `bin/rails silas:chat`.
  #
  # The dev-loop equivalent of a hosted platform's CLI — except there is no
  # platform: this runs inside your app, so tools hit your real dev database
  # and the transcript is rows in your own Postgres. Parked approvals prompt
  # inline and call the exact same approve!/decline! as the inbox and Slack.
  #
  # IO is injected so the loop is testable; the rake task wires $stdin/$stdout
  # and forces the synchronous :inline adapter (a REPL wants each turn settled
  # before the next prompt, and the dev-default Async adapter is unsafe).
  class Chat
    GLYPH = { "completed" => "✓", "failed" => "✗", "pending" => "⏸",
              "started" => "…", "in_doubt" => "?" }.freeze

    def initialize(io_in: $stdin, io_out: $stdout, actor: ENV["USER"] || "cli", session: nil)
      @in = io_in
      @out = io_out
      @actor = actor
      @session = session
    end

    def run
      banner
      if @session && pending_for(@session).exists? # resuming a session that parked last time
        settle_parked
        print_outcome(@session.turns.reload.last)
      end

      loop do
        @out.print "\nyou> "
        line = @in.gets
        break if line.nil?

        line = line.strip
        next if line.empty?
        break if %w[exit quit].include?(line.downcase)

        submit(line)
      end
      @out.puts "bye — session #{@session.id}" if @session
    end

    private

    # AGENT=clerk resumes/starts against a named agent (app/agents/clerk/).
    def agent_handle
      @agent_handle ||= ENV["AGENT"].present? ? Silas.agent(ENV["AGENT"]) : Silas.agent
    end

    def banner
      description = agent_handle.description.presence || "your agent"
      label = ENV["AGENT"].present? ? "#{ENV['AGENT']} — " : ""
      @out.puts "Silas chat — #{label}#{description} (#{agent_handle.model})."
      @out.puts "Approvals prompt inline. 'exit' or Ctrl-D to quit."
      @out.puts "Resuming session #{@session.id} (#{@session.turns.count} turns)." if @session
    end

    def submit(text)
      turn =
        if @session.nil?
          @session = agent_handle.start(input: text)
          @session.turns.first
        else
          @session.continue(input: text)
        end
      # start/continue enqueue the loop job; the :inline adapter has already run
      # it synchronously by the time they return.
      report(turn)
    rescue TurnInProgressError
      @out.puts "! a turn is still parked awaiting approval — settle it first:"
      settle_parked
      print_outcome(@session.turns.reload.last)
    end

    def report(turn)
      turn.reload
      print_trace(turn)

      if turn.parked?
        settle_parked
        settle_budget_park(turn.reload)
        turn.reload
      end

      print_outcome(turn)
    end

    def print_outcome(turn)
      turn.reload
      case turn.status
      when "completed"
        @out.puts "agent> #{turn.answer_text}"
      when "waiting", "in_doubt"
        if turn.budget_parked?
          @out.puts "(parked: #{turn.failure_reason} budget reached — resume with " \
                    "turn.raise_budget! or from a fresh silas:chat)"
        else
          @out.puts "(parked — #{pending_for(turn.session).count} approval(s) still pending; " \
                    "they also render in /silas/inbox)"
        end
      when "failed"
        @out.puts "(turn failed: #{turn.failure_reason})"
      end
    end

    # A budget-parked turn prompts for a top-up right in the terminal. The
    # resume runs synchronously on the :inline adapter, so new work (and
    # possibly another park) follows immediately.
    def settle_budget_park(turn)
      return unless turn.budget_parked?

      reason = turn.failure_reason
      @out.puts "\nbudget reached — #{reason}"
      @out.print "raise #{reason} to (blank to leave parked)> "
      value = @in.gets&.strip
      return if value.blank?

      numeric = reason == "max_cost" ? value.to_f : value.to_i
      turn.raise_budget!(**{ reason.to_sym => numeric })
      print_trace(turn.reload)
    end

    def print_trace(turn)
      ToolInvocation.where(turn_id: turn.id).order(:id).each do |inv|
        gate = inv.approval_state == "required" ? " — awaiting approval" : ""
        @out.puts "  #{GLYPH.fetch(inv.status, '·')} #{inv.tool_name}(#{compact_args(inv.arguments)})#{gate}"
      end
    end

    # Prompt for every parked approval in the session. Approving resumes the
    # turn synchronously (inline adapter), so new invocations may appear —
    # loop until nothing is pending or the user skips.
    def settle_parked
      loop do
        invocation = pending_for(@session).order(:id).first
        break unless invocation

        @out.puts "\napproval needed — #{invocation.tool_name}(#{compact_args(invocation.arguments)})"
        @out.print "approve? [y]es / [d]ecline / [s]kip> "
        answer = @in.gets&.strip&.downcase

        case answer
        when "y", "yes"
          invocation.approve!(by: @actor)
          @out.puts
          print_trace(@session.turns.reload.last)
        when "d", "decline"
          @out.print "reason> "
          reason = @in.gets&.strip
          invocation.decline!(reason: reason.presence || "declined from CLI", by: @actor)
        else
          @out.puts "(left parked — approve later here or in /silas/inbox)"
          break
        end
      end
    end

    def pending_for(session)
      session.pending_approvals.where(status: %w[pending in_doubt])
    end

    def compact_args(arguments)
      (arguments || {}).map { |key, value| "#{key}: #{value.inspect}" }.join(", ")
    end
  end
end
