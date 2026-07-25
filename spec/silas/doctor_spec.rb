require "rails_helper"

RSpec.describe Silas::Doctor do
  def check(label, checks = described_class.run(root: DummyApp.root))
    checks.find { |c| c.label.include?(label) } or raise "no check labelled #{label.inspect} in #{checks.map(&:label)}"
  end

  it "passes migrations and validates the dummy agent's tools" do
    expect(check("migrations").status).to eq(:pass)
    expect(check("tools").status).to eq(:pass)
  end

  it "resolves the default model against the registry with its prices" do
    c = check("model")
    expect(c.status).to eq(:pass)
    expect(c.detail).to include("anthropic")
  end

  it "fails the model check for an id the registry doesn't know" do
    Silas.configure { |c| c.default_model = "totally-made-up-model" }
    c = check("model")
    expect(c.status).to eq(:fail)
    expect(c.detail).to match(/refresh!/)
  end

  it "fails provider credentials when no key is configured, passes once one is" do
    expect(check("provider credentials").status).to eq(:fail)

    allow(RubyLLM.config).to receive(:anthropic_api_key).and_return("sk-test")
    c = check("provider credentials")
    expect(c.status).to eq(:pass)
    expect(c.detail).to include("anthropic")
  end

  it "warns that deny-by-default auth leaves the surfaces invisible, passes once wired" do
    expect(check("inbox auth").status).to eq(:warn)
    expect(check("api auth").status).to eq(:warn)

    Silas.configure do |c|
      c.inbox_auth = ->(_controller) {}
      c.api_auth = ->(_controller) {}
    end
    expect(check("inbox auth").status).to eq(:pass)
    expect(check("api auth").status).to eq(:pass)
  end

  it "warns about a missing rescuer entry (the dummy app has no recurring.yml)" do
    c = check("rescuer")
    expect(c.status).to eq(:warn)
  end

  it "flags the async queue adapter as a failure" do
    adapter = double(class: double(name: "ActiveJob::QueueAdapters::AsyncAdapter"))
    allow(ActiveJob::Base).to receive(:queue_adapter).and_return(adapter)
    c = check("queue adapter")
    expect(c.status).to eq(:fail)
    expect(c.detail).to match(/solid_queue/)
  end
end
