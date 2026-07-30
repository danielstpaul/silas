require "rails_helper"

# The staff console: the roster, the agent record, and the cross-agent held
# queue — the three routes that turn the approval inbox into the place you
# manage a staff of agents.
RSpec.describe "the staff console", type: :request do
  def allow_inbox!
    Silas.configure { |c| c.inbox_auth = ->(_controller) { } }
  end

  def held_invocation!(agent_name: "agent", tool: "issue_refund", expires_in: 3.days)
    session = Silas::Session.create!(agent_name: agent_name)
    turn = Silas::Turn.create!(session: session, index: 0, input: "refund order 42", status: "waiting")
    step = Silas::Step.create!(turn: turn, index: 0, status: "completed", terminal: false)
    Silas::ToolInvocation.create!(step: step, turn: turn, tool_call_id: SecureRandom.uuid,
                                  tool_name: tool, arguments: { "amount" => 120 },
                                  effect_mode: "at_most_once", approval_state: "required",
                                  approval_expires_at: expires_in.from_now)
  end

  describe "deny-by-default auth" do
    it "404s the new routes when nothing is configured" do
      get "/silas/inbox/held"
      expect(response).to have_http_status(:not_found)
      get "/silas/inbox/staff"
      expect(response).to have_http_status(:not_found)
      get "/silas/inbox/staff/agent"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "/silas/inbox/held" do
    it "shows every waiting decision across agents, soonest-expiring first" do
      allow_inbox!
      later = held_invocation!(agent_name: "agent", expires_in: 5.days)
      sooner = held_invocation!(agent_name: "scribe", expires_in: 1.day)

      get "/silas/inbox/held"

      expect(response.body).to include("issue_refund")
      expect(response.body).to include("scribe")
      # Sooner-expiring renders before later-expiring.
      expect(response.body.index("session ##{sooner.turn.session_id}"))
        .to be < response.body.index("session ##{later.turn.session_id}")
    end

    it "treats an empty queue as the good news it is" do
      allow_inbox!
      get "/silas/inbox/held"
      expect(response.body).to include("Nothing needs you")
    end
  end

  describe "/silas/inbox/staff" do
    it "lists the root agent, disk agents, and history-only agents marked gone" do
      allow_inbox!
      Silas::Session.create!(agent_name: "departed")

      get "/silas/inbox/staff"

      expect(response.body).to include(">agent<")
      expect(response.body).to include("departed")
      expect(response.body).to include("gone")
      # The dummy app's named agents come from its app/agents directory.
      Silas.named_agent_scopes.keys.each { |name| expect(response.body).to include(name) }
    end

    it "counts held decisions per agent" do
      allow_inbox!
      held_invocation!(agent_name: "agent")
      get "/silas/inbox/staff"
      expect(response.body).to include("1 held")
    end
  end

  describe "/silas/inbox/staff/:name" do
    it "renders the record: tools with effect modes and approval policies" do
      allow_inbox!
      get "/silas/inbox/staff/agent"

      expect(response).to have_http_status(:ok)
      Silas.tool_definitions.first(1).each do |definition|
        expect(response.body).to include(definition["name"])
      end
    end

    it "renders a named agent's record through its own scope" do
      allow_inbox!
      Silas::Registry.install!(root: DummyApp.root)
      name = Silas.named_agent_scopes.keys.first
      expect(name).to be_present

      get "/silas/inbox/staff/#{name}"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(name)
    end

    it "404s an unknown agent" do
      allow_inbox!
      get "/silas/inbox/staff/nonexistent"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "the sessions index Held group" do
    it "shows a held session even when it is older than a full page of newer sessions" do
      allow_inbox!
      held = held_invocation!(agent_name: "agent")
      51.times { Silas::Session.create!(agent_name: "agent") }

      get "/silas/inbox"

      expect(response.body).to include("Held")
      expect(response.body).to include("/silas/inbox/sessions/#{held.turn.session_id}")
    end
  end
end
