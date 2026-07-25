require "rails_helper"

RSpec.describe "ask_question" do
  include ActiveJob::TestHelper

  let(:session) { Silas::Session.create! }

  # Turn 0: the model asks a question at step 0, then answers with text at
  # step 1 (which it only reaches once the question is settled).
  def asking_script
    lambda do |context|
      if context[:index].zero?
        EngineScripts.result(
          blocks: [ { "type" => "text", "text" => "let me check" } ],
          tool_calls: [ Silas::Adapters::ToolCall.new(id: "q0", name: "ask_question",
                                                      arguments: { "question" => "Which environment, staging or prod?" }) ]
        )
      else
        EngineScripts.result(blocks: [ { "type" => "text", "text" => "done" } ])
      end
    end
  end

  def configure!(engine)
    Silas.configure do |c|
      c.adapter = engine
      c.isolate_steps = false
      c.tool_resolver = ->(name) do
        raise "unexpected tool #{name}" unless name == "ask_question"

        Silas::Tools::AskQuestion.new
      end
    end
  end

  def park_a_question!
    engine = FakeEngine.new(&asking_script)
    configure!(engine)
    turn = session.continue(input: "deploy it", enqueue: false)
    Silas::AgentLoopJob.perform_now(turn.id)
    [ turn.reload, Silas::ToolInvocation.find_by!(tool_call_id: "q0"), engine ]
  end

  describe "the park" do
    it "parks the turn with the question awaiting a human, without executing anything" do
      turn, invocation, = park_a_question!

      expect(turn.status).to eq("waiting")
      expect(invocation).to have_attributes(status: "pending", approval_state: "required")
      expect(invocation.arguments["question"]).to eq("Which environment, staging or prod?")
      expect(invocation.approval_expires_at).to be_within(1.minute).of(Silas.config.approval_ttl.from_now)
    end

    it "emits park.silas with reason question" do
      events = []
      callback = ->(*args) { events << ActiveSupport::Notifications::Event.new(*args) }
      ActiveSupport::Notifications.subscribed(callback, "park.silas") do
        park_a_question!
      end

      expect(events.map { |e| e.payload[:reason] }).to include("question")
    end
  end

  describe "answering" do
    it "resumes the turn with the answer as the tool result — the full round trip" do
      turn, invocation, engine = park_a_question!

      invocation.answer!(text: "staging, always", by: "op@example.test")
      perform_enqueued_jobs # the fresh resume job

      expect(turn.reload.status).to eq("completed")
      expect(invocation.reload).to have_attributes(
        status: "completed", approval_state: "answered", approved_by: "op@example.test",
        result: { "answer" => "staging, always" }
      )

      # Step 1's model call saw the answer in its replayed history.
      step1 = engine.calls.find { |c| c[:step_index] == 1 }
      expect(step1[:roles]).to eq(%w[user assistant tool])
    end

    it "instruments the answer as approval.silas action answered" do
      _, invocation, = park_a_question!

      events = []
      callback = ->(*args) { events << ActiveSupport::Notifications::Event.new(*args) }
      ActiveSupport::Notifications.subscribed(callback, "approval.silas") do
        invocation.answer!(text: "staging")
      end

      expect(events.sole.payload).to include(action: "answered", tool: "ask_question")
    end

    it "refuses a blank answer — decline! is the refusal path" do
      _, invocation, = park_a_question!

      expect { invocation.answer!(text: "   ") }.to raise_error(Silas::Error, /cannot be blank/)
      expect(invocation.reload.approval_state).to eq("required") # still parked
    end

    it "refuses answer! on a non-question invocation" do
      turn = Silas::Turn.create!(session: session, index: 5, input: "x", status: "running")
      step = Silas::Step.create!(turn: turn, index: 0)
      other = Silas::ToolInvocation.create!(step: step, turn: turn, tool_call_id: "t9",
                                            tool_name: "issue_refund", effect_mode: "transactional",
                                            arguments: {}, approval_state: "required")

      expect { other.answer!(text: "yes") }.to raise_error(Silas::Error, /not a question/)
    end
  end

  describe "the wrong verdicts" do
    it "refuses approve! on a question (answer! is the verdict)" do
      _, invocation, = park_a_question!

      expect { invocation.approve! }.to raise_error(Silas::Error, /answer!/)
      expect(invocation.reload).to have_attributes(status: "pending", approval_state: "required")
    end

    it "allows decline! — a refusal the model sees as {denied:}" do
      turn, invocation, = park_a_question!

      invocation.decline!(reason: "not telling", by: "op")
      perform_enqueued_jobs

      expect(invocation.reload.result).to eq({ "denied" => "not telling" })
      expect(turn.reload.status).to eq("completed") # the loop continued past it
    end
  end

  describe "expiry" do
    it "expires an unanswered question with a question-shaped result and fails the turn" do
      turn, invocation, = park_a_question!
      invocation.update!(approval_expires_at: 1.hour.ago)

      Silas::ToolInvocation.expire_stale!

      expect(invocation.reload).to have_attributes(approval_state: "expired", status: "failed")
      expect(invocation.result).to eq({ "answer" => nil, "note" => "question expired unanswered" })
      expect(turn.reload.status).to eq("failed")
    end
  end

  describe "registration and the digest" do
    it "advertises ask_question by default and removes it when config disables it" do
      on = Silas::Registry.new(root: DummyApp.root)
      expect(on.definitions.map { |d| d["name"] }).to include("ask_question")
      digest_on = on.digest

      Silas.config.ask_question = false
      off = Silas::Registry.new(root: DummyApp.root)
      expect(off.definitions.map { |d| d["name"] }).not_to include("ask_question")

      # The point of the config escape hatch: flipping it changes the digest,
      # which is exactly why parked turns must be settled first.
      expect(off.digest).not_to eq(digest_on)
    end
  end

  describe "the inbox answer endpoint", type: :request do
    it "answers the question through the same code path" do
      _, invocation, = park_a_question!
      allow(Silas.config).to receive(:inbox_auth).and_return(->(_c) { }) # allow

      post "/silas/inbox/invocations/#{invocation.id}/answer", params: { text: "staging" }

      expect(response).to redirect_to("/silas/inbox/sessions/#{session.id}")
      expect(invocation.reload).to have_attributes(approval_state: "answered",
                                                   result: { "answer" => "staging" })
    end

    it "bounces a blank answer back with the error" do
      _, invocation, = park_a_question!
      allow(Silas.config).to receive(:inbox_auth).and_return(->(_c) { })

      post "/silas/inbox/invocations/#{invocation.id}/answer", params: { text: "" }

      expect(response).to redirect_to("/silas/inbox/sessions/#{session.id}")
      expect(flash[:alert]).to match(/cannot be blank/)
      expect(invocation.reload.approval_state).to eq("required")
    end

    it "renders the question card, not approve/decline, in the trace" do
      _, invocation, = park_a_question!
      allow(Silas.config).to receive(:inbox_auth).and_return(->(_c) { })

      get "/silas/inbox/sessions/#{session.id}"

      expect(response.body).to include("The agent has a question")
      expect(response.body).to include("Which environment, staging or prod?")
      expect(response.body).to include("/silas/inbox/invocations/#{invocation.id}/answer")
      expect(response.body).not_to include("Approval needed — ask_question")
    end
  end

  describe "the API answer endpoint", type: :request do
    before do
      allow(Silas.config).to receive(:api_auth).and_return(->(_c) { }) # allow
    end

    it "answers with { text: } and returns the settled invocation" do
      _, invocation, = park_a_question!

      post "/silas/api/v1/approvals/#{invocation.id}/answer",
           params: { text: "staging" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("approval_state" => "answered")
      expect(invocation.reload.result).to eq({ "answer" => "staging" })
    end

    it "409s a blank answer" do
      _, invocation, = park_a_question!

      post "/silas/api/v1/approvals/#{invocation.id}/answer", params: { text: "" }, as: :json

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["error"]).to match(/cannot be blank/)
    end
  end
end
