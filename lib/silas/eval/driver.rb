module Silas
  module Eval
    # Drives ONE scenario to its resting state through the REAL framework loop
    # (Silas.agent.start + AgentLoopJob.perform_now inline), then hands back a
    # Transcript. In fake mode the ScriptedEngine supplies the model's decisions;
    # the real Ledger runs the real tools.
    module Driver
      module_function

      def drive(scenario, root: Rails.root)
        prior_adapter = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :test
        configure!(scenario, root)

        session = Silas.agent.start(input: scenario.input, metadata: scenario.metadata)
        turn = session.turns.order(:index).last
        Silas::AgentLoopJob.perform_now(turn.id)

        scenario.approvals.each do |tool|
          inv = turn.reload.tool_invocations.find { |i| i.tool_name == tool && i.approval_state == "required" }
          next unless inv

          inv.approve!(by: "eval")
          Silas::AgentLoopJob.perform_now(turn.id)
        end

        Transcript.new(turn.reload, session.reload)
      ensure
        ActiveJob::Base.queue_adapter = prior_adapter
      end

      def configure!(scenario, root)
        Silas::Registry.install!(root: root)
        engine = scenario.real? ? nil : ScriptedEngine.new(scenario.steps)
        base_resolver = Silas.config.tool_resolver
        Silas.configure do |c|
          c.engine = engine if engine
          c.isolate_steps = false
          c.max_steps = scenario.max_steps if scenario.max_steps
          if scenario.stubs.any?
            c.tool_resolver = ->(name) { scenario.stubs[name] || base_resolver.call(name) }
          end
        end
      end
    end
  end
end
