# Slack channel: the support engineer @mentions the agent in a team channel
# (e.g. #support); replies and the Approve/Decline card post back into that same
# thread — which is operator-visible, so the approval never leaks to a customer.
# Requires credentials.silas.slack.{signing_secret,bot_token}. Inbound + button
# handling live in Silas's mounted engine.
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
