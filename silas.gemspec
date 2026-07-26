require_relative "lib/silas/version"

Gem::Specification.new do |spec|
  spec.name        = "silas"
  spec.version     = Silas::VERSION
  spec.authors     = [ "Daniel St Paul" ]
  spec.email       = [ "danielstpaul@hotmail.com" ]

  spec.summary     = "Durable AI agents on the Rails you already run."
  spec.description = "An agent framework where your Rails app is the chassis: " \
                     "app/agent/ directory convention, durable runs on Active Job " \
                     "Continuations, exactly-once tool execution via a transactional " \
                     "ledger, approvals that park at zero compute."
  spec.homepage    = "https://github.com/danielstpaul/silas"
  spec.license     = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["documentation_uri"] = "#{spec.homepage}/tree/main/docs"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.required_ruby_version = ">= 3.2"

  # config/** is REQUIRED: the engine draws its routes (inbox, Slack, email) from
  # config/routes.rb — omitting it mounts a routes-less engine that 404s everything.
  # docs/** + DEPLOY.md ship IN the gem (eve's move): a coding agent driving the
  # install reads the real docs from the bundle instead of guessing, and the
  # README's links resolve for anyone with the gem and no network.
  spec.files = Dir["lib/**/*", "app/**/*", "config/**/*", "db/migrate/*", "docs/**/*",
                   "LICENSE", "README.md", "CHANGELOG.md", "DEPLOY.md"]

  spec.add_dependency "rails", ">= 8.1"     # Active Job Continuations
  spec.add_dependency "ruby_llm", ">= 1.0", "< 2"  # the :ruby_llm engine + Tool param DSL (2.0 removes APIs we rely on)

  spec.add_development_dependency "rspec-rails", "~> 7.0"
  spec.add_development_dependency "sqlite3"
  spec.add_development_dependency "pg", "~> 1.5.0"
  spec.add_development_dependency "solid_queue", ">= 1.2" # continuations support landed in 1.2
end
