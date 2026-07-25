source "https://rubygems.org"

gemspec

# Dev/test only — hermetic integration specs. Path gem inside the monorepo,
# the published gem everywhere else (standalone CI). Not a runtime dependency:
# Silas only duck-types against it.
if File.directory?(File.expand_path("../hermetic", __dir__))
  gem "hermetic", path: "../hermetic"
else
  gem "hermetic", "~> 0.1"
end

# Lint/quality (dev only). Omakase = Rails' own style baseline.
gem "rubocop-rails-omakase", require: false
gem "simplecov", require: false
gem "brakeman", require: false
gem "bundler-audit", require: false
