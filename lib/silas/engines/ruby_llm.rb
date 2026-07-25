module Silas
  module Engines
    # The :ruby_llm adapter: ONE model call per step, streamed, with tool
    # interception. Silas's Ledger owns tool execution, so tools are registered
    # as halt-proxies — RubyLLM sees the schemas, but the moment the model
    # requests a tool the proxy halts the chat loop and the calls are handed
    # back to the framework untouched.
    class RubyLLM < Base
      INTERCEPTED = "__silas_intercepted__".freeze

      def execute_step(context, &on_event)
        chat = build_chat(context, &on_event)

        response = ActiveSupport::Notifications.instrument("silas.step",
                                                           turn_id: context[:turn]&.id,
                                                           index: context[:index],
                                                           model: context[:model]) do
          if on_event
            # Streamed: RubyLLM's accumulator returns a Message identical in
            # shape to the sync path, so to_result needs no branch. Chunks with
            # tool-call fragments carry nil/empty content — only text streams.
            chat.complete do |chunk|
              text = chunk.content
              on_event.call(Event.new(type: :text_delta, payload: { text: text })) if text.is_a?(String) && !text.empty?
            end
          else
            chat.complete
          end
        end

        to_result(chat, response)
      end

      private

      def build_chat(context, &on_event)
        chat = begin
          ::RubyLLM.chat(model: context[:model])
        rescue ::RubyLLM::ModelNotFoundError
          raise Silas::Error,
                "Model #{context[:model].inspect} is not in ruby_llm's model registry. " \
                "Newer models may need a registry refresh (`RubyLLM.models.refresh!`), " \
                "or pick a registry-known model in config.default_model / agent.yml."
        end
        chat.with_instructions(context[:system]) if context[:system].present?
        # agent.yml's final_answer schema: RubyLLM renders the provider's
        # structured-output dialect and JSON-parses the response back to a
        # Hash — which to_result persists as a "structured" block.
        chat.with_schema(context[:final_answer]) if context[:final_answer].present?
        context[:tools].each { |definition| chat.with_tool(HaltProxy.new(definition)) }

        replay_history(chat, context[:messages])

        if on_event
          # before_message replaces the deprecated on_new_message (gone in
          # RubyLLM 2.0). Under streaming it fires BEFORE the HTTP request —
          # deliberate; don't "fix" the earlier timing.
          chat.before_message { on_event.call(Event.new(type: :message_start, payload: {})) }
        end
        chat
      end

      # Rebuild the provider conversation from Silas's canonical rows. The last
      # user message is delivered via ask-equivalent add_message; RubyLLM sends
      # the whole array on complete.
      def replay_history(chat, messages)
        i = 0
        while i < messages.length
          msg = messages[i]
          case msg[:role]
          when "user"
            chat.add_message(role: :user, content: msg[:content])
            i += 1
          when "assistant"
            chat.add_message(
              role: :assistant,
              content: text_from(msg[:content]),
              tool_calls: tool_calls_from(msg[:content])
            )
            i += 1
          when "tool"
            # Anthropic requires every tool_result for one assistant turn to sit
            # in a single user message. The model can emit parallel tool_use
            # blocks, so batch all consecutive tool results into one Raw message
            # (a one-element batch is the ordinary single-tool-call case).
            first_id = msg[:tool_call_id]
            blocks = []
            while i < messages.length && messages[i][:role] == "tool"
              t = messages[i]
              blocks << {
                type: "tool_result",
                tool_use_id: t[:tool_call_id],
                content: JSON.generate(t[:content])
              }
              i += 1
            end
            chat.add_message(role: :tool, tool_call_id: first_id,
                             content: ::RubyLLM::Content::Raw.new(blocks))
          else
            i += 1
          end
        end
      end

      def text_from(blocks)
        Array(blocks).select { |b| b["type"] == "text" }.map { |b| b["text"] }.join
      end

      def tool_calls_from(blocks)
        calls = Array(blocks).select { |b| b["type"] == "tool_call" }
        return nil if calls.empty?

        calls.to_h do |b|
          [ b["id"], ::RubyLLM::ToolCall.new(id: b["id"], name: b["name"], arguments: b["arguments"]) ]
        end
      end

      # The halt-proxies stop the loop after the assistant's tool_use message
      # was recorded on the chat; pull the LAST assistant message for the step.
      def to_result(chat, response)
        assistant = chat.messages.reverse.find { |m| m.role.to_s == "assistant" } || response

        blocks = []
        content = assistant.content
        if content.is_a?(Hash)
          # with_schema active: RubyLLM parsed the response to a Hash. Persist
          # it as its own block type — content.to_s here would write Ruby's
          # Hash#inspect string into the transcript as "text".
          blocks << { "type" => "structured", "data" => content }
        elsif content.to_s.present?
          blocks << { "type" => "text", "text" => content.to_s }
        end

        tool_calls = (assistant.tool_calls || {}).values.map do |tc|
          blocks << { "type" => "tool_call", "id" => tc.id, "name" => tc.name,
                      "arguments" => tc.arguments || {} }
          ToolCall.new(id: tc.id, name: tc.name, arguments: (tc.arguments || {}).stringify_keys)
        end

        Result.new(
          blocks: blocks,
          tool_calls: tool_calls,
          stop_reason: tool_calls.any? ? "tool_use" : "end_turn",
          usage: { input_tokens: assistant.tokens&.input, output_tokens: assistant.tokens&.output }
        )
      end

      # Presents an Silas tool schema to RubyLLM; halts instead of executing.
      class HaltProxy < ::RubyLLM::Tool
        def initialize(definition)
          super()
          @definition = definition
        end

        def name = @definition["name"]
        def description = @definition["description"]
        def params_schema = @definition["input_schema"]

        def execute(**)
          ::RubyLLM::Tool::Halt.new(INTERCEPTED)
        end
      end
    end
  end
end
