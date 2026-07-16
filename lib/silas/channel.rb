module Silas
  # A channel binds an external surface (email, Slack, HTTP) to the durable loop.
  # Identity is the filename (app/agent/channels/slack.rb -> Agent::Channels::Slack).
  #
  # Inbound is pure trigger reuse: dispatch maps an external thread to a Session
  # via silas_sessions.channel + continuation_token, then calls the UNCHANGED
  # public API (new thread -> Silas.agent.start; reply -> session.continue).
  # Outbound (deliver the agent's answer / an approval request) is a subclass
  # responsibility, invoked off the loop by ChannelDeliveryJob — so the loop's
  # determinism and the ledger's exactly-once are never touched.
  class Channel
    TOKEN_PURPOSE = "silas/channel".freeze

    def self.channel_name = name.demodulize.underscore

    # Stable external-thread key, namespaced by channel so two channels can't collide.
    def self.namespaced(thread_key) = "#{channel_name}:#{thread_key}"

    # The single inbound entry point for every transport.
    def self.dispatch(thread_key:, input:, metadata: {})
      token = namespaced(thread_key)
      if (session = Silas::Session.find_by(continuation_token: token))
        session.continue(input: input)
        session
      else
        Silas.agent.start(input: input, metadata: metadata,
                          channel: channel_name, continuation_token: token)
      end
    rescue ActiveRecord::RecordNotUnique
      # Concurrent first-inbound race: the other request created the session;
      # treat this message as a continue.
      session = Silas::Session.find_by!(continuation_token: namespaced(thread_key))
      session.continue(input: input)
      session
    end

    # Resolve the channel instance that owns a session (for outbound delivery).
    def self.for_session(session)
      return nil if session.channel.blank?

      klass = Silas.config.channel_resolver&.call(session.channel)
      klass&.new
    end

    # Signed token for email approve/decline links (no session state leaks into the URL).
    def self.token_for(invocation, action)
      verifier.generate({ "id" => invocation.id, "action" => action.to_s }, expires_in: Silas.config.approval_ttl)
    end

    def self.verify_token(token)
      verifier.verify(token)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveSupport::MessageEncryptor::InvalidMessage
      nil
    end

    def self.verifier
      Rails.application.message_verifier(TOKEN_PURPOSE)
    end

    # --- outbound interface (subclasses implement) ---
    def deliver_answer(session:, text:)
      raise NotImplementedError, "#{self.class}#deliver_answer"
    end

    def deliver_approval(session:, invocation:)
      raise NotImplementedError, "#{self.class}#deliver_approval"
    end
  end
end
