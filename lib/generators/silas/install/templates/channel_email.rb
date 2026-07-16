# Email channel: outbound delivery for sessions started from email. Inbound
# routing is via Action Mailbox (route mail to Silas::AgentMailbox in your
# app/mailboxes/application_mailbox.rb). Delete this file to disable email.
class Agent::Channels::Email < Silas::Channel
  def deliver_answer(session:, text:)
    email = session.metadata["email"] || {}
    Silas::ChannelMailer.answer(
      to: email["from"], subject: "Re: #{email['subject']}", text: text
    ).deliver_later
  end

  def deliver_approval(session:, invocation:)
    email = session.metadata["email"] || {}
    Silas::ChannelMailer.approval(
      to: email["from"], subject: "Approval needed: #{invocation.tool_name}", invocation: invocation
    ).deliver_later
  end
end
