module Silas
  # Action Mailbox reference inbound: maps an email thread to a Silas session.
  # A new thread starts a session; a reply (same References/In-Reply-To root)
  # continues it. Route inbound mail here from the host's ApplicationMailbox:
  #   routing all: "Silas::AgentMailbox"
  # Requires app/agent/channels/email.rb (Agent::Channels::Email) to exist.
  class AgentMailbox < ActionMailbox::Base
    def process
      channel_class.dispatch(
        thread_key: self.class.thread_key(mail),
        input: body_text,
        metadata: { "email" => { "from" => mail.from&.first, "subject" => mail.subject } }
      )
    rescue Silas::TurnInProgressError
      # A reply arriving while a turn is active is dropped (v1 single-active-turn).
    end

    # The thread root: References head, else In-Reply-To, else this Message-ID.
    def self.thread_key(mail)
      (Array(mail.references).first || mail.in_reply_to || mail.message_id).to_s
    end

    private

    def channel_class
      Silas.config.channel_resolver&.call("email") or
        raise Silas::Error, "no app/agent/channels/email.rb (Agent::Channels::Email) defined"
    end

    def body_text
      part = mail.multipart? ? (mail.text_part || mail.parts.first) : mail
      part&.decoded.to_s.strip
    end
  end
end
