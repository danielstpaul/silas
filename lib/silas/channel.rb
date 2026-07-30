module Silas
  # A channel binds an external surface (email, Slack, HTTP) to the durable loop.
  # Identity is the filename (app/agent/channels/slack.rb -> Agent::Channels::Slack).
  #
  # Inbound is pure trigger reuse: dispatch maps an external thread to a Session
  # via silas_sessions.channel + continuation_token, then calls the UNCHANGED
  # public API (new thread -> the routed agent's .start; reply -> continue).
  # Outbound (deliver the agent's answer / an approval request) is a subclass
  # responsibility, invoked off the loop by ChannelDeliveryJob — so the loop's
  # determinism and the ledger's exactly-once are never touched.
  class Channel
    TOKEN_PURPOSE = "silas/channel".freeze
    # silas_sessions.agent_name for the root app/agent — the column's default,
    # and the name the loop reads as "no named scope".
    ROOT_AGENT = "agent".freeze

    def self.channel_name = name.demodulize.underscore

    # Stable external-thread key, namespaced by channel AND agent: two channels
    # can't collide, and two staff members sharing one transport can't either.
    def self.namespaced(thread_key, agent_name = nil)
      "#{channel_name}:#{agent_name.presence || ROOT_AGENT}:#{thread_key}"
    end

    # Tokens minted before routing existed have no agent segment. Every one of
    # them belongs to the root agent — dispatch could start nothing else — so a
    # miss on the new form falls back to this one and a live thread upgrades
    # without losing its session.
    def self.legacy_namespaced(thread_key) = "#{channel_name}:#{thread_key}"

    def self.find_session(thread_key, agent_name)
      Silas::Session.find_by(continuation_token: namespaced(thread_key, agent_name)) ||
        Silas::Session.find_by(continuation_token: legacy_namespaced(thread_key))
    end

    # The single inbound entry point for every transport. `agent` is the NAME of
    # the staff member this thread belongs to (nil or "agent" = the root agent);
    # callers read it off configuration with .route_for.
    def self.dispatch(thread_key:, input:, metadata: {}, agent: nil)
      name = resolve_agent(agent)
      if (session = find_session(thread_key, name))
        session.continue(input: input)
        session
      else
        owner = name ? Silas.agent(name) : Silas.agent
        owner.start(input: input, metadata: metadata,
                    channel: channel_name, continuation_token: namespaced(thread_key, name))
      end
    rescue ActiveRecord::RecordNotUnique
      # Concurrent first-inbound race: the other request created the session;
      # treat this message as a continue. Nothing to continue means the conflict
      # was something else, so let it out.
      session = find_session(thread_key, name) or raise
      session.continue(input: input)
      session
    end

    # ---- routing: which agent an inbound thread wakes -----------------------

    # config.channel_routes, normalised to { transport => { key => agent_name } }.
    # Keys are matched downcased because email recipients are case-insensitive;
    # Slack channel ids are unaffected by folding both sides the same way.
    def self.routes
      (Silas.config.channel_routes || {}).to_h do |transport, table|
        [ transport.to_s, table.to_h { |key, agent| [ key.to_s.downcase, agent.to_s ] } ]
      end
    end

    # The agent name a thread on `transport` belongs to, or nil for the root
    # agent. Candidate keys are tried in order and the first match wins, so a
    # caller holding several (an email's recipients) passes them all.
    def self.route_for(transport, *keys)
      table = routes[transport.to_s] or return nil

      keys.flatten.filter_map { |key| table[key.to_s.downcase] }.first
    end

    # Checked at boot by Registry.install! against the app/agents/ roster. A
    # route naming an agent that doesn't exist is a deploy failure, not a
    # runtime one: Silas.agent raises on an unknown name, and discovering that
    # at dispatch time would strand every future message on the thread.
    def self.validate_routes!(staff)
      staff = staff.map(&:to_s)
      routes.each do |transport, table|
        table.each do |key, agent|
          next if agent == ROOT_AGENT || staff.include?(agent)

          raise Error, "config.channel_routes[#{transport.inspect}][#{key.inspect}] routes to " \
                       "agent #{agent.inspect}, which does not exist" \
                       "#{staff.any? ? " (known: #{staff.sort.join(', ')})" : " — no app/agents/ directories found"}"
        end
      end
    end

    # nil means the root agent. An unknown name resolves to nil instead of
    # raising: dispatch runs inside a webhook handler, and a 500 there is a
    # message Slack retries into its own retry guard and then loses. Boot
    # already refused a bad route, so this only fires when routes were assigned
    # after boot — the thread lands on the root agent, exactly where it landed
    # before routing existed, and the log says so.
    def self.resolve_agent(name)
      name = name.to_s
      return nil if name.empty? || name == ROOT_AGENT
      return name if Silas.named_agent?(name)

      Rails.logger&.error("[Silas] channel route names unknown agent #{name.inspect}; " \
                          "starting the root agent instead. Fix config.channel_routes.")
      nil
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

    # A full one-click approve/decline URL for ANY transport — the signed token
    # is the credential, so the link works in a WhatsApp message, a Discord
    # embed, or an SMS exactly as it does in email.
    #
    # Built from the engine's own route set plus the discovered mount point,
    # because a channel runs in a delivery job with no routing scope. The host
    # is required and never guessed: a hostless approval link is a dead link,
    # so this raises with the fix rather than shipping one.
    def self.approval_url(invocation, action, host: nil)
      options = default_url_options.merge(host: host || default_url_options[:host])
      if options[:host].blank?
        raise Error, "Silas::Channel.approval_url needs a host. Set " \
                     "config.action_mailer.default_url_options = { host: \"example.com\" } " \
                     "(or Rails.application.routes.default_url_options), or pass host:."
      end

      Silas::Engine.routes.url_helpers.channels_approval_url(
        token: token_for(invocation, action),
        script_name: Silas::Inbox.mount_path, **options
      )
    end

    def self.default_url_options
      mailer = Rails.application.config.action_mailer.default_url_options || {}
      Rails.application.routes.default_url_options.merge(mailer)
    end
    private_class_method :default_url_options

    # --- outbound interface (subclasses implement) ---
    def deliver_answer(session:, text:)
      raise NotImplementedError, "#{self.class}#deliver_answer"
    end

    def deliver_approval(session:, invocation:)
      raise NotImplementedError, "#{self.class}#deliver_approval"
    end

    # OPTIONAL: ask_question parks ping this instead of deliver_approval —
    # define it on transports that can collect free text (the question is
    # invocation.arguments["question"]; settle with invocation.answer!).
    # Channels without it are simply not pinged; the question waits in the
    # inbox. Deliberately NOT declared here raising NotImplementedError:
    # respond_to? is the capability check.
  end
end
