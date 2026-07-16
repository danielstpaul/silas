module Silas
  module Eval
    # Opt-in LLM judge for assert_rubric. Offline-skippable so the deterministic
    # gate never depends on a live model unless you ask for it.
    module Grader
      module_function

      def available? = ENV["SILAS_EVAL_OFFLINE"] != "1" && !grader.nil?
      def grade(prompt) = grader.call(prompt).to_s.strip

      def grader
        Silas.config.eval_grader || builtin
      end

      def builtin
        return nil if ENV["ANTHROPIC_API_KEY"].blank?

        lambda do |prompt|
          ::RubyLLM.chat(model: ENV["SILAS_EVAL_GRADER_MODEL"] || "claude-haiku-4-5-20251001")
                   .ask(prompt).content.to_s
        end
      end

      def prompt(transcript, criteria)
        calls = transcript.invocations.map { |i| "#{i.tool_name}(#{i.arguments}) => #{i.result}" }.join("; ")
        <<~PROMPT
          You are grading an AI agent transcript. Reply with exactly one line: "PASS" or "FAIL: <reason>".
          Criteria: #{criteria}

          User: #{transcript.input}
          Tool calls: #{calls}
          Final answer: #{transcript.final_text}
        PROMPT
      end
    end
  end
end
