require "rails_helper"

# Two holders of the same rendered approval card — two people, a double-click,
# a retried POST. The verdict must be a state transition, not a write.
RSpec.describe "approval races", type: :model do
  let(:session) { Silas::Session.create! }
  let(:turn) { Silas::Turn.create!(session: session, index: 0, input: "hi", status: "waiting") }
  let(:step) { Silas::Step.create!(turn: turn, index: 0) }

  def gated_invocation(tool: "issue_refund", call_id: SecureRandom.uuid)
    Silas::ToolInvocation.create!(
      step: step, turn: turn, tool_name: tool, tool_call_id: call_id,
      arguments: {}, status: "pending", approval_state: "required", effect_mode: "transactional"
    )
  end

  describe "a second verdict on the same invocation" do
    it "loses loudly rather than enqueuing a second job" do
      invocation = gated_invocation
      other = Silas::ToolInvocation.find(invocation.id) # a second stale card

      expect { invocation.approve!(by: "dana@example.com") }
        .to have_enqueued_job(Silas::AgentLoopJob)

      expect { other.approve!(by: "sam@example.com") }
        .to raise_error(Silas::Error, /already settled/)
    end

    it "does not let a decline overwrite an approval" do
      invocation = gated_invocation
      other = Silas::ToolInvocation.find(invocation.id)

      invocation.approve!(by: "dana@example.com")
      expect { other.decline!(reason: "changed my mind", by: "sam@example.com") }
        .to raise_error(Silas::Error, /already settled/)

      invocation.reload
      expect(invocation.approval_state).to eq("approved")
      expect(invocation.approved_by).to eq("dana@example.com")
    end

    it "names the winner in the error, so the loser's UI can say what happened" do
      invocation = gated_invocation
      other = Silas::ToolInvocation.find(invocation.id)
      invocation.approve!(by: "dana@example.com")

      expect { other.approve!(by: "sam@example.com") }
        .to raise_error(Silas::Error, /dana@example.com/)
    end

    it "applies to questions settled twice" do
      invocation = gated_invocation(tool: "ask_question")
      other = Silas::ToolInvocation.find(invocation.id)

      invocation.answer!(text: "yes", by: "dana@example.com")
      expect { other.answer!(text: "no", by: "sam@example.com") }
        .to raise_error(Silas::Error, /already settled/)
      expect(invocation.reload.result).to eq({ "answer" => "yes" })
    end
  end

  describe "two gated invocations on one step, settled concurrently" do
    it "enqueues exactly one resume" do
      first = gated_invocation(tool: "issue_refund")
      second = gated_invocation(tool: "send_email")

      # Neither resumes while a sibling is still gated.
      expect { first.approve!(by: "dana@example.com") }
        .not_to have_enqueued_job(Silas::AgentLoopJob)

      # The last verdict resumes — exactly once.
      expect { second.approve!(by: "dana@example.com") }
        .to have_enqueued_job(Silas::AgentLoopJob).exactly(:once)

      expect(turn.reload.status).to eq("queued")
    end

    it "does not double-enqueue when the turn was already moved out of parked" do
      first = gated_invocation(tool: "issue_refund")
      first.approve!(by: "dana@example.com")

      # Someone/something already resumed the turn (a racing sibling verdict).
      turn.update!(status: "running")
      second = gated_invocation(tool: "send_email")

      expect { second.approve!(by: "dana@example.com") }
        .not_to have_enqueued_job(Silas::AgentLoopJob)
    end
  end

  it "still records the settled state on the winning verdict" do
    invocation = gated_invocation
    invocation.approve!(by: "dana@example.com")

    invocation.reload
    expect(invocation.approval_state).to eq("approved")
    expect(invocation.status).to eq("pending")
    expect(invocation.approved_by).to eq("dana@example.com")
  end
end
