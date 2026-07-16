module Silas
  # Outbound email for the email channel: the agent's answer, and an approval
  # request rendering two signed one-click links.
  class ChannelMailer < ActionMailer::Base
    def answer(to:, subject:, text:)
      @text = text
      mail(to: to, subject: subject) { |f| f.text { render plain: text } }
    end

    def approval(to:, subject:, invocation:)
      @invocation = invocation
      @approve_token = Silas::Channel.token_for(invocation, "approve")
      @decline_token = Silas::Channel.token_for(invocation, "decline")
      mail(to: to, subject: subject)
    end
  end
end
