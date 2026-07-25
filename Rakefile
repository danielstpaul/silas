# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

# Zeitwerk naming check against the inline dummy app. Eager-loading every
# constant is the only way a naming violation surfaces before production —
# unit tests load lazily and never notice.
namespace :zeitwerk do
  desc "Eager-load the whole engine and fail on any Zeitwerk naming violation"
  task :check do
    # This task loads the spec harness to boot the dummy app, but runs no
    # examples — so SimpleCov would measure ~45% and fail the coverage floor.
    # Coverage is the spec task's job, not this one's.
    ENV["COVERAGE"] = "0"
    require_relative "spec/rails_helper"
    Zeitwerk::Loader.eager_load_all
    puts "zeitwerk: all constants eager-loaded cleanly"
  end
end

task default: :spec
