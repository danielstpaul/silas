require "yaml"

module Silas
  # A typed MCP integration declared by app/agent/connections/<name>.yml. Filename
  # is identity. Holds the credential PATH, never the secret (resolved from Rails
  # credentials at call time). Data-only (eve's shape).
  class Connection
    TRANSPORTS = %w[http].freeze
    APPROVALS  = %i[never once always].freeze
    EFFECTS    = %i[at_most_once idempotent].freeze # not transactional: a remote call can't share our DB txn

    attr_reader :name, :transport, :url, :approval, :effect

    def self.parse(path)
      attrs = YAML.safe_load(File.read(path)) || {}
      attrs.empty? ? nil : new(File.basename(path, ".yml"), attrs)
    end

    def initialize(name, attrs)
      @name = name
      @transport = attrs.fetch("transport", "http")
      @url = attrs["url"]
      @auth = attrs["auth"] || {}
      @approval = (attrs["approval"] || "never").to_sym
      @effect = (attrs["effect"] || "at_most_once").to_sym
      validate!
    end

    def client = Mcp::Client.new(url: url, headers: auth_headers)

    def auth_headers
      case @auth["type"]
      when "bearer" then { "Authorization" => "Bearer #{secret!}" }
      when "header" then { @auth.fetch("header") => secret! }
      else {}
      end
    end

    private

    def secret!
      path = @auth.fetch("credential")
      val = Rails.application.credentials.dig(*path.split(".").map(&:to_sym))
      raise Error, "connection #{name}: missing credential #{path.inspect}" if val.blank?

      val
    end

    def validate!
      raise Error, "connection #{name}: url required" if url.blank?
      raise Error, "connection #{name}: transport #{transport.inspect} unsupported (v1: http)" unless TRANSPORTS.include?(transport)
      raise Error, "connection #{name}: approval #{approval.inspect} invalid" unless APPROVALS.include?(approval)
      raise Error, "connection #{name}: effect #{effect.inspect} invalid" unless EFFECTS.include?(effect)
      # Never send a credential over plaintext: an auth'd connection must be
      # https (loopback exempt for local development servers). Boot-time and
      # loud, like every other connection misconfiguration.
      if @auth["type"].present? && plaintext_remote?
        raise Error, "connection #{name}: refusing to send credentials over plaintext http — " \
                     "use https (localhost/127.0.0.1 are exempt)"
      end
    end

    def plaintext_remote?
      uri = URI(url)
      uri.scheme == "http" && !%w[localhost 127.0.0.1 ::1].include?(uri.host)
    rescue URI::InvalidURIError
      true # an unparseable url with auth configured fails closed
    end

    # One remote tool, resolved. Quacks like a resolved Silas::Tool for the
    # Ledger (approval_policy / effect_mode / session= / call) without being a
    # Silas::Tool subclass — its schema is the remote inputSchema.
    class RemoteTool
      attr_accessor :session

      def initialize(connection:, remote_name:, client: nil)
        @connection = connection
        @remote_name = remote_name
        @client = client || connection.client
      end

      def approval_policy = @connection.approval
      def effect_mode     = @connection.effect

      def call(**args)
        @client.call_tool(@remote_name, args.deep_stringify_keys) ||
          { "isError" => true, "content" => [ { "type" => "text", "text" => "no result" } ] }
      end
    end
  end
end
