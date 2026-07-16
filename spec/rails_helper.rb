ENV["RAILS_ENV"] = "test"

require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "action_controller/railtie" # inbox request specs
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
end

DummyApp.initialize!

# Mount the engine so inbox request specs can hit /silas/inbox.
Rails.application.routes.draw do
  mount Silas::Engine => "/silas"
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
  config.use_transactional_fixtures = true
  config.filter_run_excluding :smoke unless ENV["ANTHROPIC_API_KEY"].present?
  config.expect_with(:rspec) { |c| c.max_formatted_output_length = 1000 }
  config.after { Silas.reset_configuration! }
end
