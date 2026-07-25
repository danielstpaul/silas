module Silas
  module Adapters
    # The :ruby_llm adapter: ONE model call per step, streamed, with the tool
    # calls handed back unexecuted.
    #
    # RubyLLM's `Chat#complete` runs the whole agentic loop — model, run tools,
    # feed results back, model again. Silas needs a single move, because the
    # step boundary IS the durability boundary (checkpoint, ledger, park). So
    # Chat is used as the BUILDER it is — it owns model resolution, schema
    # normalisation, system instructions and message construction — and the
    # execution goes one layer down to `Provider#complete`, which is exactly
    # what Chat itself calls for a single turn.
    #
    # Everything here is RubyLLM's public API: Chat's attr_readers (model,
    # messages, tools, schema, tool_prefs), Provider.resolve, and
    # Provider#complete. (Until 0.5 this used tool proxies that threw
    # `RubyLLM::Tool::Halt` to abort the loop from inside — RubyLLM 2.0 removes
    # Halt precisely because the loop became caller-controlled, so this binding
    # is both simpler now and the forward-compatible one.)
    class RubyLLM < Base
      def execute_step(context, &on_event)
        chat = build_chat(context)

        response = Silas.instrument(:step,
                                    turn_id: context[:turn]&.id,
                                    index: context[:index],
                                    model: context[:model]) do
          if on_event
            # Fires before the HTTP request, matching what RubyLLM's
            # before_message callback did under streaming — but ours, and
            # explicitly ordered rather than incidentally so.
            on_event.call(Event.new(type: :message_start, payload: {}))
            complete(chat) do |chunk|
              # Chunks carrying tool-call fragments have nil/empty content —
              # only text streams.
              text = chunk.content
              on_event.call(Event.new(type: :text_delta, payload: { text: text })) if text.is_a?(String) && !text.empty?
            end
          else
            complete(chat)
          end
        end

        to_result(response, schema: chat.schema)
      end

      private

      # One turn, tools advertised but never run. Streamed and sync return the
      # same Message shape (the stream accumulator builds it), so there is no
      # branch below this point.
      def complete(chat, &block)
        provider_for(chat.model).complete(
          chat.messages,
          tools: chat.tools,
          tool_prefs: chat.tool_prefs,
          temperature: nil,
          model: chat.model,
          schema: chat.schema,
          &block
        )
      end

      # Resolved from the model Chat already resolved, so the two can never
      # disagree. Memoised per provider slug: the adapter instance is itself
      # memoised on Silas (and dropped whenever config changes), and building a
      # provider builds a Faraday connection — not something to redo per step.
      # A benign race here costs one extra connection, never correctness.
      def provider_for(model_info)
        @providers ||= {}
        @providers[model_info.provider] ||=
          ::RubyLLM::Provider.resolve(model_info.provider).new(::RubyLLM.config)
      end

      def build_chat(context)
        chat = begin
          ::RubyLLM.chat(model: context[:model])
        rescue ::RubyLLM::ModelNotFoundError
          raise Silas::Error,
                "Model #{context[:model].inspect} is not in ruby_llm's model registry. " \
                "Newer models may need a registry refresh (`RubyLLM.models.refresh!`), " \
                "or pick a registry-known model in config.default_model / agent.yml."
        end
        chat.with_instructions(context[:system]) if context[:system].present?
        # agent.yml's final_answer schema: with_schema renders the provider's
        # structured-output dialect. The response comes back as a JSON string
        # (Chat#complete would have parsed it for us) — to_result does that.
        chat.with_schema(context[:final_answer]) if context[:final_answer].present?
        # with_tools (plural), not with_tool — 2.0 drops the singular form and
        # the plural exists in both.
        context[:tools].each { |definition| chat.with_tools(SchemaProxy.new(definition)) }

        replay_history(chat, context[:messages])
        chat
      end

      # Rebuild the provider conversation from Silas's canonical rows. The last
      # user message is delivered via ask-equivalent add_message; the whole
      # array goes to the provider on complete.
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

      def to_result(assistant, schema:)
        blocks = []
        content = structured_content(assistant, schema:)
        if content.is_a?(Hash)
          # with_schema active: persist the parsed payload as its own block type
          # — content.to_s here would write Ruby's Hash#inspect string into the
          # transcript as "text".
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

      # Chat#complete normally JSON-parses a schema response before handing it
      # back; calling the provider directly means we do it. A response that
      # doesn't parse stays a string rather than raising — a malformed payload
      # is the model's problem to see in the transcript, not a crash.
      def structured_content(assistant, schema:)
        content = assistant.content
        return content unless schema && content.is_a?(String) && !assistant.tool_call?

        begin
          JSON.parse(content)
        rescue JSON::ParserError
          content
        end
      end

      # Carries a Silas tool's schema to the provider. Subclasses RubyLLM::Tool
      # so it satisfies whatever the provider tool-renderers read (today: name,
      # description, params_schema, parameters, provider_params) without Silas
      # having to track that list.
      #
      # It has no #execute on purpose. Nothing calls it — the ledger owns tool
      # execution — and RubyLLM::Tool#execute raises NotImplementedError, so if
      # anything ever did, it fails loudly instead of feeding the model a
      # sentinel.
      class SchemaProxy < ::RubyLLM::Tool
        def initialize(definition)
          super()
          @definition = definition
        end

        def name = @definition["name"]
        def description = @definition["description"]

        # RubyLLM 1.x reads params_schema; 2.0 renames it parameters_schema
        # (alongside parameters -> declared_parameters and provider_params ->
        # provider_options, which we inherit rather than override). Answering to
        # both is two lines and makes the proxy version-agnostic — confirmed
        # against ruby_llm edge by the CI canary.
        def params_schema = @definition["input_schema"]
        def parameters_schema = @definition["input_schema"]
      end
    end
  end
end
