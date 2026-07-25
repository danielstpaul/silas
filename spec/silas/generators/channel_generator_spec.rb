require "rails_helper"
require "generators/silas/channel/channel_generator"
require "fileutils"

RSpec.describe Silas::Generators::ChannelGenerator do
  let(:destination) { File.expand_path("../../../tmp/generator", __dir__) }

  def generate(name)
    FileUtils.rm_rf(destination)
    FileUtils.mkdir_p(File.join(destination, "config"))
    File.write(File.join(destination, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")

    generator = described_class.new([ name ], [], destination_root: destination)
    generator.shell.mute { generator.invoke_all }
  end

  def read(path) = File.read(File.join(destination, path))

  after { FileUtils.rm_rf(destination) }

  describe "what it writes" do
    before { generate("whatsapp") }

    it "scaffolds both halves and the route that joins them" do
      expect(File).to exist(File.join(destination, "app/agent/channels/whatsapp.rb"))
      expect(File).to exist(File.join(destination, "app/controllers/agent/channels/whatsapp_controller.rb"))
      expect(read("config/routes.rb"))
        .to include('post "/agent/channels/whatsapp", to: "agent/channels/whatsapp#create"')
    end

    # Channel identity is the filename; the constant must match what
    # Registry#channels resolves via `name.camelize`, or the channel silently
    # never loads.
    it "names the constants the registry will look for" do
      expect(read("app/agent/channels/whatsapp.rb"))
        .to include("class Agent::Channels::Whatsapp < Silas::Channel")
      expect(read("app/controllers/agent/channels/whatsapp_controller.rb"))
        .to include("class Agent::Channels::WhatsappController")
    end

    it "generates valid Ruby (the templates are code, and code rots silently)" do
      %w[app/agent/channels/whatsapp.rb app/controllers/agent/channels/whatsapp_controller.rb].each do |path|
        expect { RubyVM::InstructionSequence.compile(read(path)) }.not_to raise_error
      end
    end

    it "wires the controller to its own channel class" do
      expect(read("app/controllers/agent/channels/whatsapp_controller.rb"))
        .to include("Agent::Channels::Whatsapp.dispatch")
    end
  end

  describe "the security posture it ships with" do
    before { generate("whatsapp") }

    let(:controller) { read("app/controllers/agent/channels/whatsapp_controller.rb") }
    let(:channel) { read("app/agent/channels/whatsapp.rb") }

    # A generated webhook that verifies nothing is an open door into someone's
    # agent. These four properties are the reason the generator exists.
    it "verifies the signature before doing anything else" do
      expect(controller).to include("before_action :verify_webhook!")
      expect(controller).to include("Silas::Webhook.verify_hmac")
      expect(controller).to include("head(:unauthorized) unless ok")
    end

    it "signs over the raw body, never re-serialized params" do
      expect(controller).to include("payload: request.raw_post")
    end

    it "pairs skip_forgery_protection with the signature check that replaces it" do
      expect(controller).to include("skip_forgery_protection")
      expect(controller).to match(/signature below IS the authentication/)
    end

    it "routes approvals to an operator and fails closed without one" do
      expect(channel).to include("Silas::Channel.approval_url(invocation, :approve)")
      expect(channel).to match(/SECURITY: an approval must reach an OPERATOR/)
      expect(channel).to include("if operator.blank?")
    end

    # An unimplemented deliver_answer that returns nil silently means the agent
    # answers into the void — the worst possible debugging experience.
    it "raises rather than silently no-op'ing where the user must fill in" do
      expect(channel.scan("NotImplementedError").size).to eq(2)
    end
  end

  describe "name validation" do
    it "accepts multi-word names" do
      generate("ms_teams")
      expect(read("app/agent/channels/ms_teams.rb")).to include("class Agent::Channels::MsTeams")
      expect(read("app/controllers/agent/channels/ms_teams_controller.rb"))
        .to include("class Agent::Channels::MsTeamsController")
    end

    # Rails normalises first, so the casing a user happens to type is not an
    # error — MsTeams and ms-teams both land on ms_teams.rb.
    it "normalises casing and dashes the way every other Rails generator does" do
      generate("MsTeams")
      expect(File).to exist(File.join(destination, "app/agent/channels/ms_teams.rb"))
    end

    # These survive normalisation as filenames but camelize to something
    # Zeitwerk cannot define, so the channel would fail at boot instead.
    it "refuses a name that cannot become a constant" do
      expect { generate("2fa") }.to raise_error(Thor::Error, /not a valid channel name/)
      expect { generate("whats app") }.to raise_error(Thor::Error, /not a valid channel name/)
    end
  end
end
