require "rails_helper"

RSpec.describe "context compaction" do
  include ActiveJob::TestHelper

  let(:session) { Silas::Session.create! }

  # A prior, completed turn with one completed step whose input_tokens is the
  # measured context size the trigger reads.
  def completed_turn!(index:, input: "turn #{index} input", context_tokens: 100)
    turn = Silas::Turn.create!(session: session, index: index, input: input, status: "completed")
    Silas::Step.create!(turn: turn, index: 0, status: "completed", terminal: true,
                        response_blocks: [ { "type" => "text", "text" => "reply #{index}" } ],
                        input_tokens: context_tokens, output_tokens: 5)
    turn
  end

  def running_turn!(index:, input: "current input")
    Silas::Turn.create!(session: session, index: index, input: input, status: "running")
  end

  # Records every summarisation context it sees; returns a fixed summary.
  def summariser(text: "THE SUMMARY")
    engine = Object.new
    contexts = []
    engine.define_singleton_method(:contexts) { contexts }
    engine.define_singleton_method(:execute_step) do |context, &_blk|
      contexts << context
      Silas::Adapters::Result.new(
        blocks: [ { "type" => "text", "text" => text } ], tool_calls: [],
        stop_reason: "end_turn", usage: { input_tokens: 42, output_tokens: 7 }
      )
    end
    engine
  end

  def configure!(engine, compact_at: 500)
    Silas.configure do |c|
      c.adapter = engine
      c.compact_at = compact_at
      c.isolate_steps = false
      c.tool_resolver = ->(_name) { raise "no tools in these specs" }
    end
  end

  describe "the trigger" do
    it "compacts prior turns when the measured context passes an integer threshold" do
      completed_turn!(index: 0, context_tokens: 600)
      turn = running_turn!(index: 1)
      engine = summariser
      configure!(engine)

      row = Silas::Compactor.ensure!(turn)

      expect(row).to have_attributes(status: "completed", summary: "THE SUMMARY",
                                     up_to_turn_index: 0, tokens_before: 600,
                                     input_tokens: 42, output_tokens: 7)
      expect(engine.contexts.size).to eq(1)
      expect(engine.contexts.first[:compaction]).to be(true)
      expect(engine.contexts.first[:tools]).to eq([])
    end

    it "does nothing below the threshold" do
      completed_turn!(index: 0, context_tokens: 100)
      configure!(summariser)

      expect(Silas::Compactor.ensure!(running_turn!(index: 1))).to be_nil
      expect(Silas::Compaction.count).to eq(0)
    end

    it "is off when compact_at is nil" do
      completed_turn!(index: 0, context_tokens: 999_999)
      configure!(summariser, compact_at: nil)

      expect(Silas::Compactor.ensure!(running_turn!(index: 1))).to be_nil
      expect(Silas::Compaction.count).to eq(0)
    end

    it "treats a Float as a fraction of the model's registry context window" do
      info = instance_double(::RubyLLM::Model::Info, context_window: 1_000)
      allow(::RubyLLM.models).to receive(:find).and_return(info)
      completed_turn!(index: 0, context_tokens: 950) # > 0.9 * 1000
      configure!(summariser, compact_at: 0.9)

      expect(Silas::Compactor.ensure!(running_turn!(index: 1))).to be_completed
    end

    it "never compacts when the window is unknown and compact_at is a fraction" do
      allow(::RubyLLM.models).to receive(:find).and_raise(StandardError, "not in registry")
      completed_turn!(index: 0, context_tokens: 999_999)
      configure!(summariser, compact_at: 0.9)

      expect(Silas::Compactor.ensure!(running_turn!(index: 1))).to be_nil
    end

    it "never compacts a session's first turn" do
      turn = running_turn!(index: 0)
      configure!(summariser)

      expect(Silas::Compactor.ensure!(turn)).to be_nil
    end
  end

  describe "exactly-once" do
    it "creates one row however many times ensure! runs (replayed step)" do
      completed_turn!(index: 0, context_tokens: 600)
      turn = running_turn!(index: 1)
      engine = summariser
      configure!(engine)

      first = Silas::Compactor.ensure!(turn)
      second = Silas::Compactor.ensure!(turn)

      expect(second.id).to eq(first.id)
      expect(Silas::Compaction.count).to eq(1)
      expect(engine.contexts.size).to eq(1) # the summary was generated once
    end

    it "finishes a pending row left by a crash mid-summary" do
      prior = completed_turn!(index: 0, context_tokens: 600)
      turn = running_turn!(index: 1)
      Silas::Compaction.create!(session: session, up_to_turn: prior, up_to_turn_index: 0,
                                status: "pending", tokens_before: 600)
      configure!(summariser)

      row = Silas::Compactor.ensure!(turn)

      expect(row).to have_attributes(status: "completed", summary: "THE SUMMARY")
      expect(Silas::Compaction.count).to eq(1)
    end
  end

  describe "MessageBuilder with a compaction row" do
    before do
      completed_turn!(index: 0, input: "very first question")
      completed_turn!(index: 1, input: "second question")
    end

    let!(:compaction) do
      Silas::Compaction.create!(session: session, up_to_turn: session.turns.first,
                                up_to_turn_index: 1, status: "completed",
                                summary: "User asked two things; both answered.",
                                tokens_before: 600)
    end

    it "replaces the covered turns with the summary preamble" do
      turn = running_turn!(index: 2, input: "third question")
      messages = Silas::MessageBuilder.call(turn, upto_index: 0)

      expect(messages.size).to eq(2)
      expect(messages.first[:role]).to eq("user")
      expect(messages.first[:content]).to include("summarised to stay within")
      expect(messages.first[:content]).to include("User asked two things; both answered.")
      expect(messages.last).to eq({ role: "user", content: "third question" })
      # Nothing from the compacted turns leaks through verbatim.
      expect(messages.map { |m| m[:content].to_s }.join).not_to include("very first question")
    end

    it "is byte-identical across builds — the determinism contract" do
      turn = running_turn!(index: 2)
      expect(Silas::MessageBuilder.call(turn, upto_index: 0))
        .to eq(Silas::MessageBuilder.call(turn, upto_index: 0))
    end

    it "keeps turns after the boundary verbatim" do
      compaction.update!(up_to_turn_index: 0) # covers only turn 0 now
      turn = running_turn!(index: 2)
      messages = Silas::MessageBuilder.call(turn, upto_index: 0)

      contents = messages.map { |m| m[:content].to_s }
      expect(contents.join).to include("second question") # turn 1 verbatim
      expect(contents.join).not_to include("very first question")
    end

    it "ignores a compaction at or beyond the turn being built" do
      # A rebuild of an older turn must not see a summary written later: the
      # row covers up_to_turn_index 1, and this turn IS index 1.
      turn = Silas::Turn.find_by!(session: session, index: 1)
      messages = Silas::MessageBuilder.call(turn, upto_index: 0)
      expect(messages.map { |m| m[:content].to_s }.join).to include("very first question")
    end
  end

  describe "recursive compaction" do
    it "folds the previous summary into the next transcript" do
      prior0 = completed_turn!(index: 0, context_tokens: 100)
      Silas::Compaction.create!(session: session, up_to_turn: prior0, up_to_turn_index: 0,
                                status: "completed", summary: "SUMMARY ONE", tokens_before: 600)
      completed_turn!(index: 1, input: "newer question", context_tokens: 700)
      turn = running_turn!(index: 2)
      engine = summariser(text: "SUMMARY TWO")
      configure!(engine)

      row = Silas::Compactor.ensure!(turn)

      expect(row.summary).to eq("SUMMARY TWO")
      transcript = engine.contexts.first[:messages].first[:content]
      expect(transcript).to include("already summarised:\nSUMMARY ONE")
      expect(transcript).to include("newer question")
      expect(transcript).not_to include("turn 0 input") # covered by SUMMARY ONE, not re-rendered
    end
  end

  describe "through the durable loop" do
    it "compacts before the step and the model sees the compacted history" do
      completed_turn!(index: 0, context_tokens: 600)

      script = lambda do |context|
        if context[:compaction]
          EngineScripts.result(blocks: [ { "type" => "text", "text" => "LOOP SUMMARY" } ])
        else
          EngineScripts.result(blocks: [ { "type" => "text", "text" => "done" } ])
        end
      end
      engine = FakeEngine.new(&script)
      configure!(engine, compact_at: 300)

      turn = session.continue(input: "next", enqueue: false)
      Silas::AgentLoopJob.perform_now(turn.id)

      expect(turn.reload.status).to eq("completed")
      expect(Silas::Compaction.sole).to have_attributes(status: "completed", summary: "LOOP SUMMARY")

      # FakeEngine records the roles of every non-compaction call it served:
      # the step saw [summary preamble, current input] — not the prior turn.
      step_call = engine.calls.find { |c| c[:step_index] == 0 }
      expect(step_call[:roles]).to eq(%w[user user])
      expect(step_call[:message_count]).to eq(2)
    end

    it "re-executes a crashed step against the identical compacted history" do
      completed_turn!(index: 0, context_tokens: 600)

      seen = [] # the exact messages arrays the model was given, per attempt
      crashed = false
      script = lambda do |context|
        if context[:compaction]
          EngineScripts.result(blocks: [ { "type" => "text", "text" => "LOOP SUMMARY" } ])
        else
          seen << Marshal.load(Marshal.dump(context[:messages]))
          unless crashed
            crashed = true
            raise RubyLLM::OverloadedError.new(nil, "529 mid-step") # transient: retried
          end
          EngineScripts.result(blocks: [ { "type" => "text", "text" => "done" } ])
        end
      end
      engine = FakeEngine.new(&script)
      configure!(engine, compact_at: 300)

      turn = session.continue(input: "next", enqueue: false)
      perform_enqueued_jobs { Silas::AgentLoopJob.perform_later(turn.id) }

      expect(turn.reload.status).to eq("completed")
      expect(Silas::Compaction.count).to eq(1)            # the claim held across the retry
      expect(seen.size).to eq(2)                          # step 0 ran twice (crash, retry)
      expect(seen.first).to eq(seen.last)                 # ...against byte-identical messages
      expect(seen.first.first[:content]).to include("LOOP SUMMARY")
    end

    it "emits compact.silas with the documented payload" do
      completed_turn!(index: 0, context_tokens: 600)
      turn = running_turn!(index: 1)
      configure!(summariser)

      events = []
      callback = ->(*args) { events << ActiveSupport::Notifications::Event.new(*args) }
      ActiveSupport::Notifications.subscribed(callback, "compact.silas") do
        Silas::Compactor.ensure!(turn)
      end

      expect(events.size).to eq(1)
      expect(events.first.payload).to include(
        session_id: session.id, turn_id: turn.id, up_to_turn_index: 0,
        tokens_before: 600, input_tokens: 42, output_tokens: 7
      )
    end
  end
end
