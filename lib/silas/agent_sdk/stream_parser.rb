require "json"

module Silas
  module AgentSdk
    # Tolerant NDJSON parser for `claude -p --output-format stream-json`. The
    # event schema is under-documented and shifts between versions, so unknown
    # lines/types must never raise. Yields Silas::Event objects; accumulates the
    # terminal Result (final text, tool_use blocks, usage, session_id).
    class StreamParser
      attr_reader :session_id, :final_text, :usage, :stop_reason, :blocks, :tool_calls

      def initialize
        @blocks = []
        @tool_calls = []
        @final_text = nil
        @usage = nil
        @session_id = nil
        @stop_reason = nil
      end

      def ingest(line)
        line = line.to_s.strip
        return if line.empty?

        event = JSON.parse(line)
        @session_id ||= event["session_id"] if event["session_id"]

        case event["type"]
        when "system"
          @session_id ||= event["session_id"]
          yield Event.new(type: :"system.#{event['subtype']}", payload: symbolize(event))
        when "assistant"
          ingest_assistant(event) { |e| yield e }
        when "user"
          yield Event.new(type: :tool_result, payload: symbolize(event))
        when "result"
          @final_text = event["result"]
          @stop_reason = event["subtype"]
          @usage = extract_usage(event)
          # The result text usually repeats the last assistant text — only add a
          # block if it isn't already captured.
          if @final_text && @blocks.none? { |b| b["type"] == "text" && b["text"] == @final_text }
            @blocks << { "type" => "text", "text" => @final_text }
          end
          yield Event.new(type: :result, payload: symbolize(event))
        else
          yield Event.new(type: :unknown, payload: symbolize(event))
        end
      rescue JSON::ParserError
        # A non-JSON line (banner, warning) — ignore.
      end

      # tool_calls stays [] on the Result: in the engine-owned path Claude Code
      # already executed the tools (through our MCP endpoint), so the framework
      # loop must not try to run them again.
      def to_result
        Engines::Result.new(blocks: @blocks, tool_calls: [], stop_reason: @stop_reason || "end_turn", usage: @usage)
      end

      private

      def ingest_assistant(event)
        Array(event.dig("message", "content")).each do |block|
          case block["type"]
          when "text"
            @blocks << { "type" => "text", "text" => block["text"] }
            yield Event.new(type: :text, payload: { text: block["text"] })
          when "tool_use"
            @tool_calls << block["id"]
            @blocks << { "type" => "tool_call", "id" => block["id"], "name" => block["name"], "arguments" => block["input"] }
            yield Event.new(type: :tool_call, payload: symbolize(block))
          end
        end
      end

      def extract_usage(event)
        u = event["usage"] || {}
        { input_tokens: u["input_tokens"], output_tokens: u["output_tokens"], cost_usd: event["total_cost_usd"] }
      end

      def symbolize(hash)
        hash.transform_keys(&:to_sym)
      end
    end
  end
end
