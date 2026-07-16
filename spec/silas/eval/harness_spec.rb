require "rails_helper"
require "tmpdir"

RSpec.describe "the eval harness" do
  # Build a transcript by hand to unit-test the assertion library.
  def transcript_with(final:, invocations:, status: "completed", input: "do it")
    session = Silas::Session.create!
    turn = Silas::Turn.create!(session: session, index: 0, input: input, status: status)
    step = Silas::Step.create!(turn: turn, index: 0, status: "completed",
                               response_blocks: [ { "type" => "text", "text" => final } ])
    invocations.each_with_index do |inv, i|
      Silas::ToolInvocation.create!(step: step, turn: turn, tool_call_id: "t#{i}",
                                    tool_name: inv[:name], effect_mode: "at_most_once",
                                    status: inv.fetch(:status, "completed"),
                                    approval_state: inv[:approval_state],
                                    arguments: inv.fetch(:arguments, {}), result: inv[:result])
    end
    Silas::Eval::Transcript.new(turn.reload, session.reload)
  end

  def run(transcript, &block)
    ctx = Silas::Eval::Assertions::Context.new(transcript)
    ctx.instance_exec(&block)
    ctx.failures
  end

  describe "assertions" do
    it "assert_tool_called / assert_tool_arg pass and fail correctly" do
      t = transcript_with(final: "done", invocations: [ { name: "refund", arguments: { "amount" => 5000 } } ])
      expect(run(t) { assert_tool_called "refund"; assert_tool_arg "refund", :amount, 5000 }).to be_empty
      expect(run(t) { assert_tool_called "email" }).to include(/expected email called/)
      expect(run(t) { assert_tool_arg "refund", :amount, 9999 }).to include(/expected 9999/)
    end

    it "assert_parked and assert_no_tool_called reflect a gated invocation" do
      t = transcript_with(final: "needs approval", status: "waiting",
                          invocations: [ { name: "refund", status: "pending", approval_state: "required" } ])
      expect(run(t) { assert_parked tool: "refund"; assert_no_tool_called "refund" }).to be_empty
    end

    it "assert_no_hallucinated_price catches invented amounts and allows grounded ones" do
      grounded = transcript_with(final: "I refunded £50.00.", input: "refund £50",
                                 invocations: [ { name: "refund", result: { "amount" => 5000 } } ]) # 5000p == £50
      expect(run(grounded) { assert_no_hallucinated_price }).to be_empty

      invented = transcript_with(final: "I refunded £73.00.", input: "refund order 9",
                                 invocations: [ { name: "refund", result: { "amount" => 5000 } } ])
      expect(run(invented) { assert_no_hallucinated_price }).to include(/ungrounded amount/)
    end
  end

  describe "the runner as a deploy gate (real loop, dummy tools)" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        example.run
      end
    end

    def write_eval(name, body)
      path = File.join(@dir, "#{name}_eval.rb")
      File.write(path, body)
    end

    it "passes a scenario that drives the real echo_note tool through the Ledger" do
      write_eval "echo", <<~RUBY
        Silas::Eval.scenario "echoes" do
          input "echo hi"
          on_step 0, call: { name: "echo_note", arguments: { text: "hi" } }
          on_step 1, text: "Echoed hi."
          expect do
            assert_tool_called "echo_note"
            assert_tool_arg    "echo_note", :text, "hi"
            assert_turn_completed
          end
        end
      RUBY
      ok = Silas::Eval::Runner.run(dir: @dir, root: DummyApp.root)
      expect(ok).to be(true)
    end

    it "fails the gate when an assertion is violated" do
      write_eval "bad", <<~RUBY
        Silas::Eval.scenario "wrong tool" do
          input "echo hi"
          on_step 0, call: { name: "echo_note", arguments: { text: "hi" } }
          expect { assert_tool_called "refund_order" }
        end
      RUBY
      ok = Silas::Eval::Runner.run(dir: @dir, root: DummyApp.root)
      expect(ok).to be(false)
    end

    it "verifies a real approval-gated tool parks (refund_order is approval :always)" do
      write_eval "park", <<~RUBY
        Silas::Eval.scenario "big refund parks" do
          input "refund order 9"
          on_step 0, call: { name: "refund_order", arguments: { order_id: "9", amount: 500000 } }
          expect do
            assert_parked tool: "refund_order"
            assert_no_tool_called "refund_order"
          end
        end
      RUBY
      expect(Silas::Eval::Runner.run(dir: @dir, root: DummyApp.root)).to be(true)
    end

    it "skips (does not fail) a real-mode scenario when offline" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return(nil)
      write_eval "real", <<~RUBY
        Silas::Eval.scenario "live" do
          mode :real
          input "hi"
          expect { assert_turn_completed }
        end
      RUBY
      expect(Silas::Eval::Runner.run(dir: @dir, root: DummyApp.root)).to be(true) # skipped, not failed
    end
  end
end
