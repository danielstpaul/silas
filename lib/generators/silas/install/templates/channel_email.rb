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
    # SECURITY: an approval must go to an OPERATOR, never to whoever started the
    # session. For an email-driven agent, session.metadata["email"]["from"] is
    # the person who emailed in — often the customer — so mailing THEM the
    # approve link lets them approve their own request. Route approvals to your
    # ops/approver inbox instead, and fail closed if it isn't configured.
    approver = ENV["SILAS_APPROVER_EMAIL"] # e.g. "approvals@yourcompany.com"
    if approver.blank?
      Rails.logger.warn("[Silas] SILAS_APPROVER_EMAIL unset — approval for " \
                        "invocation #{invocation.id} not emailed (won't send to the sender).")
      return
    end

    Silas::ChannelMailer.approval(
      to: approver, subject: "Approval needed: #{invocation.tool_name}", invocation: invocation
    ).deliver_later
  end
end
