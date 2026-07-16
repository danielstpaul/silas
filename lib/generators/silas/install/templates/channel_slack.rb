# Slack channel: outbound delivery for sessions started from Slack. Inbound and
# approval-button handling live in Silas's mounted engine (Silas::Engine).
# Requires credentials.silas.slack.{signing_secret,bot_token}. Delete this file
# to disable the Slack channel.
class Agent::Channels::Slack < Silas::Channel
  def deliver_answer(session:, text:)
    slack = session.metadata["slack"] || {}
    Silas::Slack.post_message(channel: slack["channel"], thread_ts: slack["thread_ts"], text: text)
  end

  def deliver_approval(session:, invocation:)
    slack = session.metadata["slack"] || {}
    Silas::Slack.post_message(
      channel: slack["channel"], thread_ts: slack["thread_ts"],
      text: "Approval needed: #{invocation.tool_name}",
      blocks: Silas::Slack.approval_blocks(invocation)
    )
  end
end
