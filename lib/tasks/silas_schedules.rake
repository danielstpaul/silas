namespace :silas do
  desc "Compile app/agent/schedules/** into config/recurring.yml (env: RAILS_ENV or ENV[SILAS_SCHEDULE_ENV] or production)"
  task schedules: :environment do
    Silas::Registry.install!(root: Rails.root)
    env = ENV["SILAS_SCHEDULE_ENV"] || "production"
    schedules = Silas.schedules
    Silas::Schedule::Compiler.write!(schedules, root: Rails.root, env: env)
    if schedules.empty?
      puts "silas: no schedules found under app/agent/schedules/ (managed entries cleared for #{env})"
    else
      puts "silas: compiled #{schedules.size} schedule(s) into config/recurring.yml [#{env}]:"
      schedules.sort_by(&:name).each { |s| puts "  #{s.recurring_key}  #{s.cron}  (#{s.kind})  -> #{s.name}" }
    end
  end

  namespace :schedules do
    desc "Report drift between discovered schedules and config/recurring.yml"
    task list: :environment do
      Silas::Registry.install!(root: Rails.root)
      env = ENV["SILAS_SCHEDULE_ENV"] || "production"
      drift = Silas::Schedule::Compiler.drift(Silas.schedules, root: Rails.root, env: env)
      puts "silas schedules [#{env}]:"
      puts "  discovered: #{Silas.schedules.map(&:name).sort.join(', ').then { |s| s.empty? ? '(none)' : s }}"
      unless drift[:uncompiled].empty?
        puts "  NOT COMPILED (run `bin/rails silas:schedules`): #{drift[:uncompiled].join(', ')}"
      end
      unless drift[:orphaned].empty?
        puts "  ORPHANED in recurring.yml (file deleted): #{drift[:orphaned].join(', ')}"
      end
      puts "  in sync." if drift[:uncompiled].empty? && drift[:orphaned].empty?
    end
  end
end
