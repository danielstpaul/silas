module Silas
  module Eval
    # Discovers *_eval.rb files, runs each scenario in isolation against the real
    # loop, reports, and returns a pass/fail boolean (the rake task exits 1 on false).
    module Runner
      module_function

      def run(dir:, pattern: nil, mode: nil, root: Rails.root)
        Eval.reset!
        Dir[File.join(dir, "**/*_eval.rb")].sort.each { |f| load f }
        picked = Eval.scenarios.select { |s| pattern.nil? || s.name.match?(pattern) }

        results = picked.map { |s| run_one(s.with_mode(mode), root) }
        report(results)
        results.all? { |r| r.pass? || r.skipped? }
      end

      def run_one(scenario, root = Rails.root)
        if scenario.real? && ENV["ANTHROPIC_API_KEY"].to_s.empty?
          return Result.skipped(scenario, "real mode, no ANTHROPIC_API_KEY")
        end

        transcript = Driver.drive(scenario, root: root)
        ctx = Assertions::Context.new(transcript)
        ctx.instance_exec(&scenario.assertions)
        Result.new(scenario, ctx.failures, ctx.skips)
      rescue StandardError => e
        Result.errored(scenario, e)
      end

      def report(results)
        results.each { |r| puts r.line }
        failing = results.count { |r| !(r.pass? || r.skipped?) }
        puts "\nsilas eval: #{results.size} scenarios, #{failing} failing, #{results.count(&:skipped?)} skipped"
      end
    end
  end
end
