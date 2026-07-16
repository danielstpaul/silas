require "silas/eval/scripted_engine"
require "silas/eval/dsl"
require "silas/eval/transcript"
require "silas/eval/assertions"
require "silas/eval/grader"
require "silas/eval/driver"
require "silas/eval/result"
require "silas/eval/runner"

module Silas
  # Evals: fixtures are scenarios, assertions run against the DURABLE transcript
  # (the real Session/Turn/Step/ToolInvocation rows). The harness only observes
  # the exactly-once loop; it never touches it. Written like Rails tests, run as
  # a deploy gate (non-zero exit on failure). The launch differentiator.
  module Eval
    class AssertionError < Silas::Error; end

    Scenario = Struct.new(:name, :input, :mode, :steps, :stubs, :approvals,
                          :metadata, :max_steps, :tags, :assertions, keyword_init: true) do
      def real? = mode == :real
      def with_mode(m) = m ? dup.tap { |s| s.mode = m } : self
    end

    class << self
      def scenarios = @scenarios ||= []
      def reset!    = (@scenarios = [])

      def scenario(name, tags: [], &block)
        dsl = DSL.new(name, tags)
        dsl.instance_exec(&block)
        scenarios << dsl.to_scenario
      end
    end
  end
end
