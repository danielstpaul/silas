require "rails_helper"

# SSE at row granularity with Last-Event-ID resume. ActionController::Live
# runs the action on its own thread with its own AR connection — rows must be
# committed (same pattern as the MCP server spec).
RSpec.describe "the SSE stream", type: :request do
  self.use_transactional_tests = false

  before { Silas.configure { |c| c.api_auth = ->(_controller) { } } }

  after do
    [ Silas::ToolInvocation, Silas::Step, Silas::Turn, Silas::Session ].each(&:delete_all)
  end

  let!(:session) { Silas::Session.create!(agent_name: "refunds") }
  let!(:turn) { Silas::Turn.create!(session: session, index: 0, input: "go", status: "running") }
  let!(:step) do
    Silas::Step.create!(turn: turn, index: 0, status: "completed", terminal: true,
                        response_blocks: [ { "type" => "text", "text" => "all done" } ])
  end
  let!(:invocation) do
    Silas::ToolInvocation.create!(step: step, turn: turn, tool_call_id: "t0", tool_name: "record",
                                  effect_mode: "at_most_once", arguments: {}, approval_state: "required")
  end

  def sse_events(body)
    body.split("\n\n").filter_map do |chunk|
      next if chunk.strip.empty? || chunk.start_with?(":")

      event = {}
      chunk.each_line do |line|
        key, value = line.chomp.split(": ", 2)
        event[key] = key == "data" ? JSON.parse(value) : value
      end
      event
    end
  end

  it "is deny-by-default like every other surface" do
    Silas.reset_configuration!
    get "/silas/api/v1/sessions/#{session.id}/stream", params: { poll: 1 }
    expect(response).to have_http_status(:not_found)
  end

  it "replays the whole session for Last-Event-ID: 0 and closes in poll mode" do
    get "/silas/api/v1/sessions/#{session.id}/stream",
        params: { poll: 1 }, headers: { "Last-Event-ID" => "0" }

    events = sse_events(response.body)
    types = events.map { |e| e["event"] }
    expect(types).to include("turn", "step", "invocation")

    step_event = events.find { |e| e["event"] == "step" }
    expect(step_event["data"]["text"]).to eq("all done")
    expect(step_event["id"].to_i).to be > 0

    expect(response.headers["Content-Type"]).to include("text/event-stream")
  end

  it "resumes from a watermark: old rows stay silent, fresh changes emit" do
    # Age the whole fixture two hours into the past…
    [ turn, step, invocation ].each { |row| row.update_column(:updated_at, 2.hours.ago) }
    session.update_column(:updated_at, 2.hours.ago)
    # …then make one fresh change.
    invocation.update!(approval_state: "declined", status: "failed", decline_reason: "no")

    one_hour_ago_ms = (1.hour.ago.to_f * 1000).round
    get "/silas/api/v1/sessions/#{session.id}/stream",
        params: { poll: 1 }, headers: { "Last-Event-ID" => one_hour_ago_ms.to_s }

    events = sse_events(response.body)
    expect(events.map { |e| e["event"] }).to eq([ "invocation" ])
    expect(events.sole["data"]["approval_state"]).to eq("declined")
  end

  it "closes itself with a timeout event at api_stream_max_duration (reconnect contract)" do
    Silas.configure do |c|
      c.api_auth = ->(_controller) { }
      c.api_stream_max_duration = 0 # first pass, then deadline
    end

    get "/silas/api/v1/sessions/#{session.id}/stream", headers: { "Last-Event-ID" => "0" }

    events = sse_events(response.body)
    expect(events.last["event"]).to eq("timeout")
    expect(events.last["data"]).to eq("reconnect" => true)
  end
end
