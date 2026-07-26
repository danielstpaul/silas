module Silas
  module Eval
    # Define-time recorder for the scenario DSL.
    class DSL
      def initialize(name, tags)
        @name = name
        @tags = tags
        @mode = :fake
        @steps = {}
        @stubs = {}
        @approvals = []
        @metadata = {}
        @max_steps = nil
      end

      def input(text)  = (@input = text)
      def metadata(h)  = (@metadata = h)
      def mode(m)      = (@mode = m)
      def max_steps(n) = (@max_steps = n)
      def approve(tool:) = (@approvals << tool.to_s)

      # on_step(0, text:, call: {name:, arguments:}, calls: [ {…}, … ], data: {…})
      # `data:` scripts a STRUCTURED answer (the final_answer schema case) —
      # it becomes the same {"type"=>"structured"} block the real adapter
      # persists, so assert_answer_data reads it back through Turn#answer_data.
      # Keys are stringified exactly as a JSON-parsed model response would be.
      def on_step(index, text: nil, call: nil, calls: [], data: nil)
        tcs = (calls + [ call ].compact).each_with_index.map do |c, n|
          Silas::Adapters::ToolCall.new(id: "eval_s#{index}_#{n}", name: c[:name].to_s,
                                       arguments: (c[:arguments] || {}).stringify_keys)
        end
        blocks = []
        blocks << { "type" => "structured", "data" => data.deep_stringify_keys } if data
        blocks << { "type" => "text", "text" => text } if text
        @steps[index] = { blocks: blocks, tool_calls: tcs }
      end

      # Override a real tool with a stub for a side-effect-free eval.
      def stub_tool(name, effect_mode: :at_most_once, approval: :never, &body)
        obj = Object.new
        obj.define_singleton_method(:effect_mode) { effect_mode }
        obj.define_singleton_method(:approval_policy) { approval }
        obj.singleton_class.attr_accessor :session
        obj.define_singleton_method(:call, &body)
        @stubs[name.to_s] = obj
      end

      def expect(&block) = (@assertions = block)

      def to_scenario
        raise Silas::Error, "eval #{@name.inspect} needs an input" unless @input
        raise Silas::Error, "eval #{@name.inspect} needs an expect block" unless @assertions

        Scenario.new(name: @name, input: @input, mode: @mode, steps: @steps,
                     stubs: @stubs, approvals: @approvals, metadata: @metadata,
                     max_steps: @max_steps, tags: @tags, assertions: @assertions)
      end
    end
  end
end
