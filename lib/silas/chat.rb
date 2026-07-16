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

    def banner
      description = Silas.agent.description.presence || "your agent"
      @out.puts "Silas chat — #{description} (#{Silas.agent.model})."
      @out.puts "Approvals prompt inline. 'exit' or Ctrl-D to quit."
      @out.puts "Resuming session #{@session.id} (#{@session.turns.count} turns)." if @session
    end

    def submit(text)
      turn =
        if @session.nil?
          @session = Silas.agent.start(input: text)
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
        turn.reload
      end

      print_outcome(turn)
    end

    def print_outcome(turn)
      case turn.reload.status
      when "completed"
        @out.puts "agent> #{turn.answer_text}"
      when "waiting", "in_doubt"
        @out.puts "(parked — #{pending_for(turn.session).count} approval(s) still pending; " \
                  "they also render in /silas/inbox)"
      when "failed"
        @out.puts "(turn failed: #{turn.failure_reason})"
      end
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
