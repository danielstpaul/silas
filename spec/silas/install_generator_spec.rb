require "rails_helper"
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

  it "leaves an existing ruby_llm initializer byte-identical" do
    FileUtils.mkdir_p(File.join(dest, "config/initializers"))
    existing = "RubyLLM.configure { |c| c.openai_api_key = ENV[\"MY_KEY\"] } # brownfield\n"
    File.write(File.join(dest, "config/initializers/ruby_llm.rb"), existing)

    silenced { run_generator }

    expect(File.read(File.join(dest, "config/initializers/ruby_llm.rb"))).to eq(existing)
  end

  # The generator's post-install rake step fails harmlessly in the skeleton;
  # keep its noise (stdout and stderr) out of the suite output.
  def silenced
    old_out, old_err = $stdout.dup, $stderr.dup
    $stdout.reopen(File::NULL)
    $stderr.reopen(File::NULL)
    yield
  ensure
    $stdout.reopen(old_out)
    $stderr.reopen(old_err)
  end
end
