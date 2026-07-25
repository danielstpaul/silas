require "rails_helper"

# Silas reaches into two dependencies' internals. That's justified — the
# durability contract needs them — but an upgrade that renames any of these
# breaks recovery SILENTLY, because the rescuer swallows what it can't match
# and the engine seam only fails at model-call time. These specs make such an
# upgrade fail here, loudly, instead.
RSpec.describe "dependency contracts" do
  describe "Solid Queue (the dead-job rescuer depends on these)" do
    before { skip "solid_queue not loaded" unless defined?(::SolidQueue) }

    it "still names the dead-process errors the rescuer allowlists" do
      # DeadJobRescuerJob::DEAD_PROCESS_ERRORS matches on these exact strings;
      # a rename means killed workers are never rescued and turns strand
      # forever — the failure mode the rescuer exists to prevent.
      Silas::DeadJobRescuerJob::DEAD_PROCESS_ERRORS.each do |name|
        expect { name.constantize }.not_to raise_error, "#{name} no longer exists in solid_queue"
      end
      expect(Silas::DeadJobRescuerJob::DEAD_PROCESS_ERRORS).to contain_exactly(
        "SolidQueue::Processes::ProcessExitError",
        "SolidQueue::Processes::ProcessPrunedError"
      )
    end

    it "still exposes the failed-execution API the rescuer walks" do
      expect(defined?(SolidQueue::FailedExecution)).to eq("constant")
      expect(SolidQueue::FailedExecution).to respond_to(:includes)
      # #retry is defined in the class body (not schema-derived), so it is
      # assertable without solid_queue's tables present.
      expect(SolidQueue::FailedExecution.method_defined?(:retry)).to be(true)
      expect(SolidQueue::FailedExecution.reflect_on_association(:job)).to be_present
    end

    it "still supports the continuations version the durability contract needs" do
      # Continuations landed in solid_queue 1.2; below that a resumed turn
      # silently restarts from step 0.
      expect(Gem::Version.new(SolidQueue::VERSION)).to be >= Gem::Version.new("1.2")
    end
  end

  describe "RubyLLM (the :ruby_llm adapter depends on these)" do
    # The adapter uses Chat as a BUILDER and Provider#complete as the executor.
    # Both halves are pinned here because a change to either is silent: the
    # builder half would still construct, and the executor half would still run
    # — just against a different contract than the one the ledger assumes.

    it "still exposes the chat seams the adapter builds with" do
      expect(::RubyLLM::Chat.instance_methods)
        .to include(:with_tools, :with_instructions, :with_schema, :add_message)
    end

    it "still reads back everything the adapter hands to the provider" do
      # These attr_readers ARE the handoff from builder to executor. Without
      # them the adapter would have to reach for ivars.
      expect(::RubyLLM::Chat.instance_methods)
        .to include(:model, :messages, :tools, :schema, :tool_prefs)
    end

    it "still lets a caller run one turn without executing tools" do
      # The seam the whole design rests on: Chat#complete runs the agentic loop,
      # Provider#complete runs exactly one move and hands the tool calls back.
      expect(::RubyLLM::Provider.instance_methods).to include(:complete)

      keywords = ::RubyLLM::Provider.instance_method(:complete).parameters
                                    .select { |type, _| type == :key || type == :keyreq }
                                    .map(&:last)
      expect(keywords).to include(:tools, :temperature, :model, :schema, :tool_prefs)
    end

    it "still resolves a provider from a model's provider slug" do
      # Provider.resolve(slug).new(config) is how the adapter gets an executor
      # for the model Chat already resolved.
      info = ::RubyLLM.models.find("claude-sonnet-4-5", "anthropic")
      klass = ::RubyLLM::Provider.resolve(info.provider)
      expect(klass).to be_a(Class)
      expect(klass.instance_methods).to include(:complete)
    end

    it "still reads tool schemas off the interface SchemaProxy inherits" do
      # Providers render tools by calling these; SchemaProxy subclasses
      # RubyLLM::Tool so it satisfies the list without Silas tracking it.
      #
      # When this fires, the answer is already known — 2.0 renames the trio:
      #   params_schema   -> parameters_schema  (SchemaProxy answers to both)
      #   parameters      -> declared_parameters (inherited, not overridden)
      #   provider_params -> provider_options    (inherited, not overridden)
      # so only the first needed action, and it is already taken.
      expect(::RubyLLM::Tool.instance_methods)
        .to include(:name, :description, :params_schema, :parameters, :provider_params)
    end

    it "advertises the tool schema under whichever name the installed RubyLLM reads" do
      proxy = Silas::Adapters::RubyLLM::SchemaProxy.new(
        "name" => "issue_refund", "description" => "d", "input_schema" => { "type" => "object" }
      )
      expect(proxy.name).to eq("issue_refund")
      expect(proxy.params_schema).to eq({ "type" => "object" })      # 1.x
      expect(proxy.parameters_schema).to eq({ "type" => "object" })  # 2.0
    end

    it "still raises from Tool#execute, so an unexpected call fails loudly" do
      # SchemaProxy deliberately does not implement #execute. If a future
      # RubyLLM ever routed through it, this must be an exception rather than a
      # silent value fed back to the model.
      expect { ::RubyLLM::Tool.new.execute }.to raise_error(NotImplementedError)
    end

    it "still exposes the model registry API cost accounting prices against" do
      expect(::RubyLLM.models).to respond_to(:find)
      info = ::RubyLLM.models.find("claude-sonnet-4-5", "anthropic")
      expect(info).to respond_to(:input_price_per_million, :output_price_per_million, :provider)
    end

    it "still raises ModelNotFoundError (not nil) for an unknown model" do
      # Cost.rate_for and StepRunner#provider_for rescue on this behaviour.
      expect { ::RubyLLM.models.find("definitely-not-a-model-xyz") }
        .to raise_error(::RubyLLM::ModelNotFoundError)
    end

    it "still names the transient error classes AgentLoopJob retries" do
      %w[RateLimitError OverloadedError ServiceUnavailableError ServerError
         UnauthorizedError PaymentRequiredError ForbiddenError BadRequestError].each do |err|
        expect(::RubyLLM.const_defined?(err)).to be(true), "RubyLLM::#{err} is gone — check retry_on/discard_on"
      end
    end
  end

  describe "Active Job continuations (the durable loop IS this)" do
    it "still provides the Continuable API the loop is built on" do
      expect(defined?(ActiveJob::Continuable)).to eq("constant")
      expect(Silas::AgentLoopJob.ancestors).to include(ActiveJob::Continuable)
      expect(Silas::AgentLoopJob).to respond_to(:resume_errors_after_advancing=)
    end

    it "keeps resume_errors_after_advancing FALSE so errors reach retry_on" do
      # Flipping this back re-introduces silent unbounded self-resume that
      # bypasses attempts/backoff entirely.
      expect(Silas::AgentLoopJob.resume_errors_after_advancing).to be(false)
    end
  end
end
