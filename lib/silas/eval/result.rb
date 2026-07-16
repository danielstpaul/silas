module Silas
  module Eval
    class Result
      attr_reader :scenario, :failures, :skips

      def initialize(scenario, failures = [], skips = [], skipped: false)
        @scenario = scenario
        @failures = failures
        @skips = skips
        @skipped = skipped
      end

      def self.skipped(scenario, why) = new(scenario, [], [ why ], skipped: true)
      def self.errored(scenario, error) = new(scenario, [ "ERROR: #{error.class}: #{error.message}" ])

      def pass? = @failures.empty? && !@skipped
      def skipped? = @skipped

      def line
        mark = skipped? ? "SKIP" : (pass? ? "PASS" : "FAIL")
        out = "  [#{mark}] #{@scenario.name}"
        out += "\n        - #{@failures.join("\n        - ")}" unless @failures.empty?
        out += "\n        (#{@skips.join('; ')})" unless @skips.empty?
        out
      end
    end
  end
end
