namespace :silas do
  desc "Diagnose common Silas misconfigurations (provider key, queue adapter, model, migrations, tools, rescuer, cable, auth)"
  task doctor: :environment do
    glyph = { pass: "\e[32m✓\e[0m", warn: "\e[33m!\e[0m", fail: "\e[31m✗\e[0m" }
    checks = Silas::Doctor.run

    puts "silas:doctor — #{Silas::VERSION}"
    checks.each do |check|
      puts " #{glyph[check.status]} #{check.label}#{" — #{check.detail}" if check.detail.present?}"
    end

    failed = checks.count { |c| c.status == :fail }
    warned = checks.count { |c| c.status == :warn }
    puts "\n#{failed} failure(s), #{warned} warning(s)"
    exit 1 if failed.positive?
  end
end
