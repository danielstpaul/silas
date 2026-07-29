require "rails_helper"

# Ten DOM ids ARE the live console. Turbo addresses an element that must
# already exist in the rendered page: a broadcast to an id no view renders
# raises nothing, logs nothing and changes nothing — the console simply stops
# moving. The dispatch specs in broadcasting_spec.rb stub the turbo seam and
# never render, so they cannot see an id that moved or vanished. These render.
#
# Nine of the ten come from Inbox::Broadcastable; the tenth
# (silas-step-<id>-text) from Inbox::DeltaBroadcaster. Two shapes, and the
# difference is the whole bug class:
#
#   replace — Turbo swaps the TARGET ELEMENT itself, so the broadcast partial
#     must carry the id on its OWN ROOT. A replace id living on a wrapper in
#     the parent is destroyed by the first broadcast (2026-07-26 regression).
#   append / update — the id is a CONTAINER that Turbo writes into. The parent
#     view owns it and it survives every broadcast.
RSpec.describe "the live console's DOM contract" do
  let(:session) { Silas::Session.create!(agent_name: "refunds") }
  let(:turn) { Silas::Turn.create!(session: session, index: 0, input: "refund order 42", status: "running") }
  let(:step) do
    Silas::Step.create!(turn: turn, index: 0, status: "completed",
                        response_blocks: [ { "type" => "text", "text" => "hello there" } ])
  end
  let(:invocation) do
    Silas::ToolInvocation.create!(step: step, turn: turn, tool_call_id: "t0", tool_name: "issue_refund",
                                  effect_mode: "at_most_once", arguments: { "amount" => 120 },
                                  approval_state: "required")
  end

  # Turbo's broadcast jobs render through the HOST's renderer, so that is the
  # renderer the contract has to hold under.
  def host_render(partial, locals) = ActionController::Base.render(partial: partial, locals: locals)

  def dom_id(record, prefix = nil) = ActionView::RecordIdentifier.dom_id(record, prefix)

  def expect_target(html, target, partial:)
    found = Nokogiri::HTML.fragment(html).css("##{target}").size
    expect(found).to eq(1),
      "broadcast target ##{target} is rendered #{found} time(s) by #{partial}, expected exactly 1. " \
      "Turbo needs that element to exist; a broadcast to a missing id is a silent no-op."
  end

  def expect_root_target(html, target, partial:)
    expect_target(html, target, partial: partial)
    roots = Nokogiri::HTML.fragment(html).elements
    expect(roots.map { |e| e["id"] }).to eq([ target ]),
      "##{target} is a `replace` target — Turbo swaps out the element itself — so #{partial} must " \
      "render exactly one root element carrying that id. It rendered #{roots.size} root element(s): " \
      "#{roots.map { |e| e["id"] || "(no id)" }.join(", ")}."
  end

  describe "replace targets — the id belongs on the partial's root element" do
    it "silas-turn-<id>-header <- turns/_header" do
      expect_root_target(host_render("silas/inbox/turns/header", { turn: turn }),
                         "silas-turn-#{turn.id}-header", partial: "silas/inbox/turns/_header.html.erb")
    end

    it "dom_id(step) <- steps/_step" do
      expect_root_target(host_render("silas/inbox/steps/step", { step: step }),
                         dom_id(step), partial: "silas/inbox/steps/_step.html.erb")
    end

    it "dom_id(invocation) <- invocations/_invocation, parked and settled" do
      expect_root_target(host_render("silas/inbox/invocations/invocation", { invocation: invocation }),
                         dom_id(invocation), partial: "silas/inbox/invocations/_invocation.html.erb")

      invocation.update!(approval_state: "approved", status: "completed", result: { "refund_id" => 9 })
      expect_root_target(host_render("silas/inbox/invocations/invocation", { invocation: invocation }),
                         dom_id(invocation), partial: "silas/inbox/invocations/_invocation.html.erb")
    end

    it "dom_id(invocation, :approval) <- invocations/_approval_card, parked and settled" do
      expect_root_target(host_render("silas/inbox/invocations/approval_card", { invocation: invocation }),
                         dom_id(invocation, :approval),
                         partial: "silas/inbox/invocations/_approval_card.html.erb")

      # The settled render is the replace that CLEARS the hoisted card. It has
      # to hit the same id or the card never leaves the top of the session.
      invocation.update!(approval_state: "approved", status: "completed")
      expect_root_target(host_render("silas/inbox/invocations/approval_card", { invocation: invocation }),
                         dom_id(invocation, :approval),
                         partial: "silas/inbox/invocations/_approval_card.html.erb")
    end

    it "silas-session-<id>-cost <- sessions/_cost" do
      expect_root_target(host_render("silas/inbox/sessions/cost", { session: session }),
                         "silas-session-#{session.id}-cost", partial: "silas/inbox/sessions/_cost.html.erb")
    end
  end

  describe "append containers — owned by the parent, never by the broadcast partial" do
    it "silas-turn-<id>-steps <- turns/_turn" do
      expect_target(host_render("silas/inbox/turns/turn", { turn: turn }),
                    "silas-turn-#{turn.id}-steps", partial: "silas/inbox/turns/_turn.html.erb")
    end

    it "silas-step-<id>-tools <- steps/_step" do
      expect_target(host_render("silas/inbox/steps/step", { step: step }),
                    "silas-step-#{step.id}-tools", partial: "silas/inbox/steps/_step.html.erb")
    end

    it "the step partial does not repeat its parent's append container" do
      html = host_render("silas/inbox/steps/step", { step: step })
      expect(Nokogiri::HTML.fragment(html).css("#silas-turn-#{turn.id}-steps")).to be_empty,
        "silas/inbox/steps/_step.html.erb renders #silas-turn-#{turn.id}-steps, the container it is " \
        "appended INTO — every append would nest another copy."
    end
  end

  describe "the delta target — DeltaBroadcaster writes into it mid-model-call" do
    # Unconditional on purpose: deltas start arriving before the step has any
    # persisted text, so the container cannot depend on step_text being there.
    it "silas-step-<id>-text <- steps/_step, with and without text" do
      blank = Silas::Step.create!(turn: turn, index: 1)

      [ step, blank ].each do |s|
        expect_target(host_render("silas/inbox/steps/step", { step: s }),
                      "silas-step-#{s.id}-text", partial: "silas/inbox/steps/_step.html.erb")
      end
    end
  end

  # A handoff's row is broadcast-replaced the moment it settles, and settling
  # is when it first names the session it started. So the child link is built
  # in the host renderer or not at all: bare engine helpers have no url_options
  # there and take the whole broadcast job down with them.
  describe "the lineage row inside a broadcast-rendered invocation" do
    it "links the child through the engine mount" do
      child = Silas::Session.create!(agent_name: "filer", parent_session_id: session.id,
                                     metadata: { "handoff_from" => "refunds" })
      handoff = Silas::ToolInvocation.create!(step: step, turn: turn, tool_call_id: "h0",
                                              tool_name: "handoff", effect_mode: "at_most_once",
                                              status: "completed", result: { "session_id" => child.id })

      html = host_render("silas/inbox/invocations/invocation", { invocation: handoff })
      expect(html).to include("#{Silas::Inbox.mount_path}/inbox/sessions/#{child.id}")
      expect(html).to include("handed to")
    end
  end

  describe "containers the session page owns", type: :request do
    before { Silas.configure { |c| c.inbox_auth = ->(_controller) { } } }

    it "silas-turns and silas-session-<id>-approvals <- sessions/show" do
      invocation
      get "/silas/inbox/sessions/#{session.id}"

      expect_target(response.body, "silas-turns", partial: "silas/inbox/sessions/show.html.erb")
      expect_target(response.body, "silas-session-#{session.id}-approvals",
                    partial: "silas/inbox/sessions/show.html.erb")
    end

    it "renders every per-record target the page is responsible for seeding" do
      invocation
      get "/silas/inbox/sessions/#{session.id}"

      [ "silas-turn-#{turn.id}-header", "silas-turn-#{turn.id}-steps", dom_id(step),
        "silas-step-#{step.id}-text", "silas-step-#{step.id}-tools", dom_id(invocation),
        dom_id(invocation, :approval), "silas-session-#{session.id}-cost" ].each do |target|
        expect_target(response.body, target, partial: "silas/inbox/sessions/show.html.erb")
      end
    end
  end

  # The other direction: a target ADDED to Broadcastable with no view rendering
  # it would ship as a dead broadcast. Drive every transition that broadcasts,
  # capture the seam, and hold the emitted set to the nine covered above.
  it "Broadcastable emits no target this spec does not cover" do
    allow(Silas::Inbox).to receive(:streaming?).and_return(true)
    emitted = []
    allow_any_instance_of(Silas::Inbox::Broadcastable).to receive(:silas_inbox_dispatch) do |_obj, _action, _sid, **opts|
      emitted << opts[:target]
    end

    turn # session -> turn, both creates under the stub
    running = Silas::Step.create!(turn: turn, index: 0)
    inv = Silas::ToolInvocation.create!(step: running, turn: turn, tool_call_id: "t1",
                                        tool_name: "issue_refund", effect_mode: "at_most_once")
    turn.update!(status: "waiting")
    running.update!(status: "completed")
    inv.update!(approval_state: "required")
    inv.update!(approval_state: "approved", status: "completed")

    expect(emitted.uniq).to match_array([
      "silas-turns",
      "silas-turn-#{turn.id}-steps",
      "silas-turn-#{turn.id}-header",
      "silas-step-#{running.id}-tools",
      "silas-session-#{session.id}-approvals",
      "silas-session-#{session.id}-cost",
      dom_id(running), dom_id(inv), dom_id(inv, :approval)
    ])
  end
end
