require "rails_helper"
require "tempfile"
require "generators/silas/install/install_generator"

# Brownfield safety: the installer must never touch an app's existing
# ruby_llm initializer (production provider config lives there).
RSpec.describe Silas::Generators::InstallGenerator do
  let(:dest) { Dir.mktmpdir }
  after { FileUtils.remove_entry(dest) }

  def run_generator
    # Minimal app skeleton the generator's file actions expect.
    FileUtils.mkdir_p(File.join(dest, "config/initializers"))
    File.write(File.join(dest, "config/routes.rb"),
               "Rails.application.routes.draw do\nend\n")
    described_class.start([], destination_root: dest, behavior: :invoke)
  end

  it "generates the ruby_llm initializer in a fresh app" do
    silenced { run_generator }
    expect(File.read(File.join(dest, "config/initializers/ruby_llm.rb")))
      .to include("ANTHROPIC_API_KEY")
  end

  it "installs the coding-agent skill with the load-bearing rules" do
    silenced { run_generator }
    skill = File.read(File.join(dest, ".claude/skills/silas/SKILL.md"))
    expect(skill).to start_with("---\nname: silas\n")     # valid skill frontmatter
    expect(skill).to include("transactional!")            # the effect-mode decision table
    expect(skill).to include("Never mark an external call `transactional!`")
    expect(skill).to include("NondeterminismError")       # the parked-turn deploy rule
    expect(skill).to include("bundle show silas")         # points at the bundled docs
  end

  it "leaves an existing ruby_llm initializer byte-identical" do
    FileUtils.mkdir_p(File.join(dest, "config/initializers"))
    existing = "RubyLLM.configure { |c| c.openai_api_key = ENV[\"MY_KEY\"] } # brownfield\n"
    File.write(File.join(dest, "config/initializers/ruby_llm.rb"), existing)

    silenced { run_generator }

    expect(File.read(File.join(dest, "config/initializers/ruby_llm.rb"))).to eq(existing)
  end

  it "generates a bin/ci that can actually fail on app tests (no || true)" do
    silenced { run_generator }
    ci = File.read(File.join(dest, "bin/ci"))
    expect(ci).not_to include("|| true")
    expect(ci).to include("set -e")
  end

  it "generates an initializer that shows every option the next-steps mention" do
    silenced { run_generator }
    initializer = File.read(File.join(dest, "config/initializers/silas.rb"))
    %w[inbox_auth sandbox memory_approval model_prices eval_dir approval_ttl].each do |option|
      expect(initializer).to include("config.#{option}")
    end
    expect(initializer).not_to include("claude-opus") # never default a first run to the priciest model
  end

  # The next steps end on "run silas:doctor", and doctor FAILS the :async
  # adapter Rails defaults development to. The install has to hand over the fix.
  describe "the queue-adapter remedy" do
    it "prints the config to paste when the app is on :async" do
      adapter = double(class: double(name: "ActiveJob::QueueAdapters::AsyncAdapter"))
      allow(ActiveJob::Base).to receive(:queue_adapter).and_return(adapter)

      output = silenced { run_generator }

      expect(output).to include("config.active_job.queue_adapter = :solid_queue")
      expect(output).to include("config.solid_queue.connects_to")
      expect(output).to include("bin/jobs")
      expect(output).to include("silas:doctor")
    end

    it "stays quiet on any other adapter (the suite runs on :test)" do
      output = silenced { run_generator }
      expect(output).not_to include("queue_adapter = :solid_queue")
    end

    it "writes no config files — database.yml and cable.yml belong to the host" do
      adapter = double(class: double(name: "ActiveJob::QueueAdapters::AsyncAdapter"))
      allow(ActiveJob::Base).to receive(:queue_adapter).and_return(adapter)

      silenced { run_generator }

      expect(File.exist?(File.join(dest, "config/database.yml"))).to be(false)
      expect(File.exist?(File.join(dest, "config/cable.yml"))).to be(false)
      expect(File.exist?(File.join(dest, "config/environments/development.rb"))).to be(false)
    end
  end

  describe "the rescuer recurring task" do
    let(:recurring) { File.join(dest, "config/recurring.yml") }

    it "creates a production block when no recurring.yml exists" do
      silenced { run_generator }
      content = File.read(recurring)
      expect(content).to start_with("production:")
      expect(content).to include("silas_dead_job_rescuer")
    end

    it "injects under EVERY deployable env block, never dev/test, never the file tail" do
      FileUtils.mkdir_p(File.join(dest, "config"))
      File.write(recurring, <<~YAML)
        production:
          existing_task:
            class: SomeJob

        staging:
          other_task:
            class: OtherJob

        development:
      YAML

      silenced { run_generator }
      content = File.read(recurring)

      expect(content.scan("silas_dead_job_rescuer").size).to eq(2) # production + staging
      dev_section = content.split("development:").last
      expect(dev_section).not_to include("silas_dead_job_rescuer")
      # Landed under the env headers, not appended into whatever block ends the file.
      expect(content).to match(/production:\n(  #.*\n)+  silas_dead_job_rescuer:/)
    end

    it "is idempotent — a second run never duplicates the YAML key" do
      silenced { run_generator }
      silenced { described_class.start([], destination_root: dest, behavior: :invoke) }
      expect(File.read(recurring).scan("silas_dead_job_rescuer").size).to eq(1)
    end
  end

  # The generator's post-install rake step fails harmlessly in the skeleton;
  # keep its noise (stdout and stderr) out of the suite output. Returns what
  # was written to stdout. A file, not a StringIO: the rake step is a
  # subprocess writing to fd 1, which a reassigned $stdout would never see.
  def silenced
    out = Tempfile.new("silas-install-generator")
    old_out, old_err = $stdout.dup, $stderr.dup
    $stdout.reopen(out.path, "w")
    $stderr.reopen(File::NULL)
    yield
    $stdout.flush
    File.read(out.path)
  ensure
    $stdout.reopen(old_out)
    $stderr.reopen(old_err)
    out.close!
  end
end
