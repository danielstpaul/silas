require "rails_helper"

RSpec.describe Silas::Registry do
  subject(:registry) { described_class.new(root: DummyApp.root) }

  describe "tool discovery" do
    it "discovers tools by filename with identity = filename" do
      expect(registry.tools.keys).to eq(%w[echo_note refund_order])
      expect(registry.tools["echo_note"]).to eq(Agent::Tools::EchoNote)
    end

    it "resolves fresh instances that answer the Ledger's contract" do
      tool = registry.resolver.call("echo_note")
      expect(tool.effect_mode).to eq(:transactional)
      expect(tool.approval_policy).to eq(:never)
      expect(tool.call(text: "hi")).to eq({ "echo" => "hi" })
    end
  end

  describe "schema derivation" do
    it "derives the schema from the keyword signature with param refinements" do
      schema = Agent::Tools::RefundOrder.schema
      expect(schema["name"]).to eq("refund_order")
      expect(schema["description"]).to eq("Refund an order.")
      expect(schema["input_schema"]["required"]).to eq(%w[order_id amount])
      expect(schema["input_schema"]["properties"]["amount"]).to eq(
        { "type" => "integer", "description" => "Pence" }
      )
      expect(schema["input_schema"]["properties"]["order_id"]).to eq({ "type" => "string" })
    end

    it "marks optional keywords as not required" do
      schema = Agent::Tools::EchoNote.schema
      expect(schema["input_schema"]["required"]).to eq(%w[text])
      expect(schema["input_schema"]["properties"].keys).to include("loud")
    end

    it "rejects positional arguments at validation time" do
      klass = Class.new(Silas::Tool) do
        def call(positional) = positional
      end
      expect { klass.validate_signature! }.to raise_error(Silas::Error, /keyword arguments only/)
    end
  end

  describe "skills" do
    it "parses skill frontmatter descriptions" do
      skill = registry.skills.sole
      expect(skill.name).to eq("summarize")
      expect(skill.description).to eq("How to write a good summary.")
      expect(skill.body).to include("Lead with the outcome.")
    end
  end

  describe "digest" do
    it "is stable across instances for the same definitions" do
      expect(registry.digest).to eq(described_class.new(root: DummyApp.root).digest)
    end
  end

  describe "install!" do
    it "wires resolver, definitions, and digest into config" do
      described_class.install!(root: DummyApp.root)
      expect(Silas.tool_resolver.call("echo_note")).to be_a(Agent::Tools::EchoNote)
      expect(Silas.tool_definitions.map { |d| d["name"] }).to eq(%w[echo_note refund_order load_skill delegate])
      expect(Silas.config.definitions_digest.call).to be_present
    end
  end

  describe "the nondeterminism guard" do
    it "fails a turn whose definitions digest no longer matches" do
      described_class.install!(root: DummyApp.root)
      session = Silas::Session.create!
      turn = Silas::Turn.create!(session: session, index: 0, input: "hi",
                               status: "running", definitions_digest: "stale-digest")
      expect {
        Silas::StepRunner.call(turn, 0)
      }.to raise_error(Silas::NondeterminismError, /changed mid-turn/)
      expect(turn.reload).to have_attributes(status: "failed", failure_reason: "definitions_changed")
    end
  end
end
