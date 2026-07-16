module Silas
  # Streamed event from an engine (or the framework) during a step.
  # Types: :text_delta, :tool_call, :thinking, :usage — and :approval_request,
  # which only :engine-owned loops (agent_sdk) emit; in :framework-owned loops
  # approvals are a Ledger concern, never an engine event.
  Event = Data.define(:type, :payload)

  module Engines
    # The inference seam. An engine executes exactly ONE model call for a step
    # and reports what came back; the framework owns the loop, the ledger owns
    # tool execution.
    class Base
      # :framework — Silas's AgentLoopJob drives the loop (ruby_llm).
      # :engine    — the engine drives its own loop (agent_sdk, future).
      def self.loop_ownership = :framework

      # context: { turn:, index:, system:, messages:, tools:, model:, limits: }
      # Yields Silas::Event objects as they stream; returns a Result.
      def execute_step(context, &on_event)
        raise NotImplementedError, "#{self.class} must implement #execute_step"
      end
    end

    Result = Data.define(:blocks, :tool_calls, :stop_reason, :usage) do
      def terminal? = tool_calls.empty?
    end

    ToolCall = Data.define(:id, :name, :arguments)
  end
end
