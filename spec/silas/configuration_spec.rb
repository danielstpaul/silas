require "rails_helper"

RSpec.describe Silas::Configuration do
  describe "boot guard" do
    around do |example|
      original = ENV["ANTHROPIC_API_KEY"]
      example.run
    ensure
      original.nil? ? ENV.delete("ANTHROPIC_API_KEY") : ENV["ANTHROPIC_API_KEY"] = original
    end

    it "raises when :agent_sdk + :oauth is configured while ANTHROPIC_API_KEY exists" do
      ENV["ANTHROPIC_API_KEY"] = "sk-test"
      expect {
        Silas.configure { |c| c.engine = :agent_sdk; c.auth = :oauth }
      }.to raise_error(Silas::BootGuardError, /silently override/)
    end

    it "allows :agent_sdk + :api_key with a key present" do
      ENV["ANTHROPIC_API_KEY"] = "sk-test"
      expect {
        Silas.configure { |c| c.engine = :agent_sdk; c.auth = :api_key }
      }.not_to raise_error
    end

    it "allows :agent_sdk + :oauth when no key is in the environment" do
      ENV.delete("ANTHROPIC_API_KEY")
      expect {
        Silas.configure { |c| c.engine = :agent_sdk; c.auth = :oauth }
      }.not_to raise_error
    end

    it "defaults to :ruby_llm engine with sensible config" do
      expect(Silas.config.engine).to eq(:ruby_llm)
      expect(Silas.config.default_model).to be_present
    end
  end
end
