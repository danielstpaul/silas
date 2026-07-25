ENV["RAILS_ENV"] = "test"

# Coverage BEFORE anything else loads, or nothing is instrumented. The floor
# fails the build rather than being informational — a ratchet, not a report.
# COVERAGE=0 opts out for a quick local run.
unless ENV["COVERAGE"] == "0"
  require "simplecov"
  SimpleCov.start do
    add_filter %r{^/spec/}
    add_filter %r{^/chaos_host/}
    add_filter %r{^/examples/}
    add_group "Loop",      %w[lib/silas/step_runner lib/silas/ledger app/jobs]
    add_group "Engines",   "lib/silas/engines"
    add_group "Channels",  %w[app/controllers/silas/channels app/mailboxes app/mailers]
    add_group "API",       "app/controllers/silas/api"
    add_group "Inbox",     %w[app/controllers/silas/inbox app/helpers]
    minimum_coverage line: 90 # actual is ~92%; ratchet up, never down
  end
end

require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "action_controller/railtie" # inbox + channel request specs
require "action_mailer/railtie"     # ChannelMailer
require "action_mailbox/engine"     # AgentMailbox (inbound email)
require "solid_queue"               # the rescuer couples to its internals; pin them
require "silas"

# Inline dummy app (pattern lifted from ruby_llm-resilience): no generated
# spec/dummy tree to maintain. STORE=pg switches to local Postgres, mirroring
# the spike's two-store matrix.
class DummyApp < Rails::Application
  config.root = File.expand_path("dummy", __dir__)
  config.eager_load = false
  config.hosts.clear
  config.logger = Logger.new(nil)
  config.secret_key_base = "test"
  config.action_controller.allow_forgery_protection = false # CSRF off in tests (standard)
  config.action_dispatch.show_exceptions = :none
  config.action_mailer.delivery_method = :test
  config.action_mailer.default_url_options = { host: "example.test" } # signed approval links
  config.active_storage.service_configurations = { test: { "service" => "Disk", "root" => "tmp/storage" } }
  config.active_storage.service = :test
end

DummyApp.initialize!

# Mount the engine so inbox request specs can hit /silas/inbox. The pigeon
# route is what `rails g silas:channel` injects into a host's routes.rb — a
# generated channel's webhook is served by the HOST, not the engine.
Rails.application.routes.draw do
  mount Silas::Engine => "/silas"
  post "/agent/channels/pigeon", to: "agent/channels/pigeon#create"
end

# STORE=pg selects Postgres via spec/dummy/config/database.yml (spike-matrix parity).
if ENV["STORE"] != "pg"
  require "fileutils"
  FileUtils.mkdir_p(DummyApp.root.join("tmp"))
  FileUtils.rm_f(DummyApp.root.join("tmp/silas_test.sqlite3"))
end
ActiveRecord::Base.establish_connection(:test)

# Run the engine's migrations directly against the connection.
migration_paths = [ File.expand_path("../db/migrate", __dir__) ]
ActiveRecord::MigrationContext.new(migration_paths).migrate

require "rspec/rails"
Dir[File.expand_path("support/**/*.rb", __dir__)].each { |f| require f }

RSpec.configure do |config|
  config.include ActiveSupport::Testing::TimeHelpers
  config.use_transactional_fixtures = true
  config.filter_run_excluding :smoke unless ENV["ANTHROPIC_API_KEY"].present?
  config.expect_with(:rspec) { |c| c.max_formatted_output_length = 1000 }
  config.after { Silas.reset_configuration! }
end
