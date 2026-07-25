require "rails/generators"

module Silas
  module Generators
    # rails g silas:channel whatsapp
    #
    # A channel is two halves that must agree on one name, and hand-rolling
    # them is where the mistakes live: inbound needs signature verification and
    # a stable thread key, outbound needs the approval link to reach an
    # operator. This scaffolds both, wired together, with the security
    # decisions already made.
    class ChannelGenerator < Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      desc "Scaffold a Silas channel: outbound Channel class, inbound webhook controller, and its route."

      # Channel identity is the filename (app/agent/channels/whatsapp.rb ->
      # Agent::Channels::Whatsapp), and Registry#channels resolves it with
      # `camelize`. A filename that isn't a snake_case identifier produces a
      # constant Zeitwerk can't define, and the channel then fails at boot
      # rather than here — so refuse it here, where the message is useful.
      # (Rails' usual normalisation still applies first: `MsTeams` and
      # `ms_teams` both land on ms_teams.)
      def validate_name
        return if file_name.match?(/\A[a-z_][a-z0-9_]*\z/)

        raise Thor::Error, "#{file_name.inspect} is not a valid channel name — " \
                           "it must be lowercase words separated by underscores, " \
                           "starting with a letter (e.g. whatsapp, ms_teams)."
      end

      # Templates are .rb.tt (Rails' own convention): the .tt keeps ERB-bearing
      # files out of the linter and off Zeitwerk's radar.
      def create_channel
        template "channel.rb.tt", "app/agent/channels/#{file_name}.rb"
      end

      # The webhook lives in the HOST app, not the engine: only the host knows
      # the vendor's signature scheme and payload shape. The engine ships
      # routes for Slack alone because it also ships Slack's verification.
      def create_controller
        template "controller.rb.tt", "app/controllers/agent/channels/#{file_name}_controller.rb"
      end

      def add_route
        route %(post "/agent/channels/#{file_name}", to: "agent/channels/#{file_name}#create")
      end

      def show_next_steps
        say <<~MSG, :green

          Channel "#{file_name}" scaffolded:
            app/agent/channels/#{file_name}.rb                        (outbound: answers + approvals)
            app/controllers/agent/channels/#{file_name}_controller.rb (inbound: webhook)
            config/routes.rb                                        POST /agent/channels/#{file_name}

          Next:
            1. Set the signing secret:
               bin/rails credentials:edit  ->  silas:
                                                 #{file_name}:
                                                   signing_secret: ...
            2. Fill in the three TODOs — the vendor's signature scheme, how a
               message maps to a thread key, and how to post a message back.
            3. Point the vendor's webhook at https://<your-host>/agent/channels/#{file_name}
            4. Restart: app/agent/ registers at boot.

          Full contract and a worked example: docs/channels.md
        MSG
      end
    end
  end
end
