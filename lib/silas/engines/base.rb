module Silas
  # Streamed event from an engine during a step. The type vocabulary is an open
  # set — consumers must ignore unknown types. Emitted today by Engines::RubyLLM:
  #   :message_start — once per model call (before_message)
  #   :text_delta    — { text: } chunks as the response streams
  # StepRunner coalesces :text_delta into "silas.delta" notifications (see
  # DeltaBuffer); everything else is available to custom engines/hooks.
  Event = Data.define(:type, :payload)

  module Engines
    # The inference seam. An engine executes exactly ONE model call for a step
    # and reports what came back; the framework owns the loop, the ledger owns
    # tool execution.
    class Base
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
