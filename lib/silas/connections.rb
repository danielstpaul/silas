module Silas
  # Discovery + boot-warm for app/agent/connections/*.yml. Lists each remote MCP
  # server's tools ONCE at boot (cached), surfaces them namespaced as
  # "<connection>__<tool>" (model-visible -> in the digest), and resolves those
  # names to fresh RemoteTool instances for the Ledger.
  class Connections
    def initialize(root:, client_factory: nil)
      @root = Pathname(root)
      @client_factory = client_factory
      @definitions = []
      @by_name = {}
    end

    def descriptors
      @descriptors ||= Dir[@root.join("app/agent/connections/*.yml")].sort.filter_map { |f| Connection.parse(f) }
    end

    # Boot-time tools/list, cached. Fail-loud (like the Registry's boot tool
    # validation): a misconfigured/unreachable connection raises HERE, never
    # inside a turn or a mid-turn digest check.
    def warm!
      return self if @warmed

      descriptors.each do |conn|
        client = @client_factory&.call(conn) || conn.client
        client.list_tools.each do |remote|
          ns = "#{conn.name}__#{remote['name']}"
          @definitions << {
            "name" => ns, "description" => remote["description"].to_s,
            "input_schema" => remote["inputSchema"] || { "type" => "object", "properties" => {} }
          }
          @by_name[ns] = [ conn, remote["name"] ]
        end
      rescue StandardError => e
        raise Error, "connection #{conn.name}: tools/list failed at boot — #{e.class}: #{e.message}"
      end
      @warmed = true
      self
    end

    def definitions = @definitions.dup

    def resolve(name)
      pair = @by_name[name]
      return nil unless pair

      conn, remote = pair
      client = @client_factory&.call(conn) || conn.client
      Connection::RemoteTool.new(connection: conn, remote_name: remote, client: client)
    end
  end
end
