namespace :silas do
  desc "Run agent evals as a deploy gate (exit 1 on failure). SILAS_EVAL_MODE=real for live; EVAL=regex to filter."
  task eval: :environment do
    ok = Silas::Eval::Runner.run(
      dir: ENV["SILAS_EVAL_DIR"] || Silas.config.eval_dir,
      pattern: (Regexp.new(ENV["EVAL"]) if ENV["EVAL"]),
      mode: ENV["SILAS_EVAL_MODE"]&.to_sym
    )
    exit(1) unless ok
  end

  namespace :eval do
    desc "List discovered eval scenarios without running them"
    task list: :environment do
      Silas::Eval.reset!
      Dir[File.join(Silas.config.eval_dir, "**/*_eval.rb")].sort.each { |f| load f }
      Silas::Eval.scenarios.each { |s| puts "  [#{s.mode}] #{s.name}" }
    end
  end
end
