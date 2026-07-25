module Silas
  # Streamed event from an engine during a step. The type vocabulary is an open
  # set — consumers must ignore unknown types. Emitted today by Engines::RubyLLM:
  #   :message_start — once per model call (before_message)
  #   :text_delta    — { text: } chunks as the response streams
  # StepRunner coalesces :text_delta into "delta.silas" notifications (see
  # DeltaBuffer); everything else is available to custom engines/hooks.
  Event = Data.define(:type, :payload)

  module Adapters
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

  # Renamed Engines:: -> Adapters:: in 0.4, removed in 2.0. Host apps subclass
  # Adapters::Base for custom inference backends, so the old constant keeps
  # resolving (with a warning) rather than blowing up on upgrade.
  module Engines
    def self.const_missing(name)
      Silas.deprecator.warn("Silas::Engines::#{name} is deprecated; use Silas::Adapters::#{name}")
      Silas::Adapters.const_get(name)
    end
  end
end
