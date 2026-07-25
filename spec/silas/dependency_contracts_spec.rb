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

  describe "RubyLLM (the :ruby_llm engine depends on these)" do
    it "still exposes the chat seams the engine drives" do
      chat_methods = ::RubyLLM::Chat.instance_methods
      # with_schema -> structured final answers; before_message -> :message_start
      # (on_new_message is deprecated and removed in 2.0); complete(&block) is
      # how streaming is requested.
      expect(chat_methods).to include(:with_tool, :with_instructions, :with_schema,
                                      :before_message, :complete, :add_message)
    end

    it "still provides Tool::Halt, which is how the engine intercepts tool calls" do
      expect(defined?(::RubyLLM::Tool::Halt)).to eq("constant")
      expect(::RubyLLM::Tool::Halt.new("x")).to respond_to(:content)
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
