require "rails_helper"

# final_answer: a JSON schema in agent.yml -> RubyLLM with_schema -> a
# "structured" block in the rows -> Turn#answer_data everywhere.
RSpec.describe "structured final output" do
  let(:session) { Silas::Session.create! }
  let(:turn) { Silas::Turn.create!(session: session, index: 0, input: "verdict?", status: "running", instructions_snapshot: "sys") }
  let(:payload) { { "verdict" => "approve", "amount_pence" => 1250 } }

  def structured_engine(data)
    Class.new(Silas::Adapters::Base) do
      define_method(:execute_step) do |_context, &_on_event|
        Silas::Adapters::Result.new(blocks: [ { "type" => "structured", "data" => data } ],
                                   tool_calls: [], stop_reason: "end_turn", usage: {})
      end
    end.new
  end

  def configure!(engine)
    Silas.configure do |c|
      c.adapter = engine
      c.isolate_steps = false
      c.tool_resolver = ->(_n) { raise "no tools here" }
    end
  end

  describe "definitions digest compatibility (the upgrade-safety constraint)" do
    it "is byte-identical to the pre-final_answer shape when no schema is set" do
      registry = Silas::Registry.new(root: DummyApp.root) # dummy agent.yml has no final_answer
      legacy = Digest::SHA256.hexdigest(JSON.generate({
        tools: registry.definitions,
        skills: registry.skills.map { |s| [ s.name, s.description ] }
      }))
      expect(registry.digest).to eq(legacy) # parked 0.2 turns survive the upgrade
    end

    it "changes when a schema is present — by appending the key, nothing else" do
      registry = Silas::Registry.new(root: DummyApp.root)
      schema = { "type" => "object", "properties" => { "verdict" => { "type" => "string" } } }
      allow(registry).to receive(:root_agent).and_return(Silas::Agent.new("final_answer" => schema))

      expected = Digest::SHA256.hexdigest(JSON.generate({
        tools: registry.definitions,
        skills: registry.skills.map { |s| [ s.name, s.description ] },
        final_answer: schema
      }))
      expect(registry.digest).to eq(expected)
    end
  end

  describe "the :ruby_llm engine" do
    fake_message = Struct.new(:role, :content, :tool_calls, :tokens)

    let(:fake_chat) do
      Class.new do
        attr_reader :schema, :messages

        def initialize(content) = (@content = content; @messages = [])
        def with_instructions(*) = self
        def with_schema(schema) = (@schema = schema; self)
        def with_tool(*) = self
        def before_message(&) = self
        def add_message(**) = self

        def complete(&)
          @messages << self.class.const_get(:MSG).new("assistant", @content, nil, nil)
          @messages.last
        end
      end.tap { |k| k.const_set(:MSG, fake_message) }
    end

    it "passes the schema through with_schema and persists the Hash as a structured block" do
      schema = { "type" => "object" }
      chat = fake_chat.new(payload)
      allow(::RubyLLM).to receive(:chat).and_return(chat)

      result = Silas::Adapters::RubyLLM.new.execute_step(
        turn: nil, index: 0, system: "sys", messages: [],
        tools: [], model: "claude-x", final_answer: schema, limits: {}
      )

      expect(chat.schema).to eq(schema)
      expect(result.blocks).to eq([ { "type" => "structured", "data" => payload } ])
      expect(result.terminal?).to be(true)
    end

    it "does not call with_schema when the agent has no final_answer" do
      chat = fake_chat.new("plain prose")
      allow(::RubyLLM).to receive(:chat).and_return(chat)

      result = Silas::Adapters::RubyLLM.new.execute_step(
        turn: nil, index: 0, system: nil, messages: [],
        tools: [], model: "claude-x", final_answer: nil, limits: {}
      )

      expect(chat.schema).to be_nil
      expect(result.blocks).to eq([ { "type" => "text", "text" => "plain prose" } ])
    end
  end

  describe "end to end through the rows" do
    before { configure!(structured_engine(payload)) }

    it "exposes answer_data (and keeps answer_text for prose agents)" do
      Silas::StepRunner.call(turn, 0)

      expect(turn.reload.steps.sole).to have_attributes(status: "completed", terminal: true)
      expect(turn.answer_data).to eq(payload)
      expect(turn.answer_text).to eq("")
    end

    it "replays the structured answer into later turns' history as its JSON text" do
      Silas::StepRunner.call(turn, 0)
      turn.finish!(:completed)
      turn2 = Silas::Turn.create!(session: session, index: 1, input: "and now?", status: "running")

      messages = Silas::MessageBuilder.call(turn2, upto_index: 0)
      assistant = messages.find { |m| m[:role] == "assistant" }
      expect(assistant[:content]).to eq([ { "type" => "text", "text" => JSON.generate(payload) } ])
    end
  end

  describe "eval assertion" do
    it "matches whole payloads, single keys, and predicates" do
      transcript = double(answer_data: payload)
      ctx = Silas::Eval::Assertions::Context.new(transcript)

      ctx.assert_answer_data(payload)
      ctx.assert_answer_data(key: :verdict, value: "approve")
      ctx.assert_answer_data { |d| d["amount_pence"] < 5000 }
      expect(ctx.failures).to be_empty

      ctx.assert_answer_data(key: :verdict, value: "decline")
      expect(ctx.failures.sole).to include('expected "decline"')

      empty = Silas::Eval::Assertions::Context.new(double(answer_data: nil))
      empty.assert_answer_data(payload)
      expect(empty.failures.sole).to match(/no structured answer/)
    end
  end

  describe "the REPL" do
    around do |example|
      previous = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :inline
      example.run
    ensure
      ActiveJob::Base.queue_adapter = previous
    end

    it "prints the structured payload when there is no prose answer" do
      configure!(structured_engine(payload))
      output = StringIO.new
      Silas::Chat.new(io_in: StringIO.new("verdict?\nexit\n"), io_out: output, actor: "spec").run

      expect(output.string).to include("agent> #{JSON.generate(payload)}")
    end
  end
end
