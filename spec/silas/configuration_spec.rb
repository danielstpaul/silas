require "rails_helper"

RSpec.describe Silas::Configuration do
  describe "boot guard" do
    it "raises a clear removal error when the cut :agent_sdk engine is configured" do
      expect {
        Silas.configure { |c| c.engine = :agent_sdk }
      }.to raise_error(Silas::BootGuardError, /removed in Silas 0\.2/)
    end

    it "defaults to :ruby_llm engine with sensible config" do
      expect(Silas.config.engine).to eq(:ruby_llm)
      expect(Silas.config.default_model).to be_present
    end
  end

  describe "provider-credentials boot check (:ruby_llm)" do
    it "warns (not raises) outside production when no provider key is configured" do
      expect(Rails.logger).to receive(:warn).with(/no configured provider/)
      expect { Silas.configure { |c| c.engine = :ruby_llm } }.not_to raise_error
    end

    it "raises BootGuardError in production — a keyless prod deploy is always a misconfig" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      expect {
        Silas.configure { |c| c.engine = :ruby_llm }
      }.to raise_error(Silas::BootGuardError, /no configured provider/)
    end

    it "passes silently once any provider key is present" do
      allow(RubyLLM.config).to receive(:anthropic_api_key).and_return("sk-test")
      expect(Rails.logger).not_to receive(:warn)
      expect { Silas.configure { |c| c.engine = :ruby_llm } }.not_to raise_error
    end
  end

  describe "async-adapter guard" do
    it "raises in production instead of warning" do
      adapter = double(class: double(name: "ActiveJob::QueueAdapters::AsyncAdapter"))
      allow(ActiveJob::Base).to receive(:queue_adapter).and_return(adapter)
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      allow(RubyLLM.config).to receive(:anthropic_api_key).and_return("sk-test") # isolate this guard

      expect {
        Silas.configure { |c| c.engine = :ruby_llm }
      }.to raise_error(Silas::BootGuardError, /Async queue adapter/)
    end
  end

  describe "removed :agent_sdk options" do
    it "accepts writes as warning no-ops instead of crashing an existing initializer" do
      allow(Rails.logger).to receive(:warn)
      expect {
        Silas.configure { |c| c.agent_sdk_claude_bin = "claude" }
      }.not_to raise_error
      expect(Rails.logger).to have_received(:warn).with(/config\.agent_sdk_claude_bin was removed/)
    end

    it "returns nil (with a warning) on reads" do
      allow(Rails.logger).to receive(:warn)
      expect(Silas.config.auth).to be_nil
      expect(Rails.logger).to have_received(:warn).with(/config\.auth was removed/)
    end
  end
end
