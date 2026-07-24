require "rails_helper"

RSpec.describe Silas::Inbox::DeltaBroadcaster do
  it "no-ops when streaming is unavailable (no turbo in this bundle)" do
    expect {
      described_class.broadcast({ session_id: 1, step_id: 2, text: "x" })
    }.not_to raise_error
  end

  describe "with turbo present" do
    let(:fake_channel) do
      Class.new do
        class << self
          def calls = @calls ||= []

          def broadcast_update_to(*args, **kwargs)
            calls << [ args, kwargs ]
          end
        end
      end
    end

    before { stub_const("Turbo::StreamsChannel", fake_channel) }

    it "pushes escaped accumulated text into the per-step target, synchronously" do
      described_class.broadcast({ session_id: 7, step_id: 3, text: "a<b" })

      args, kwargs = fake_channel.calls.sole
      expect(args.first).to eq("silas:inbox:session:7")
      expect(kwargs[:target]).to eq("silas-step-3-text")
      expect(kwargs[:html].to_s).to include("a&lt;b")
    end

    it "respects the inbox_streaming kill switch" do
      Silas.configure { |c| c.inbox_streaming = false }
      described_class.broadcast({ session_id: 7, step_id: 3, text: "x" })
      expect(fake_channel.calls).to be_empty
    end

    it "swallows cable failures — never re-raises into the durable loop" do
      allow(fake_channel).to receive(:broadcast_update_to).and_raise(RuntimeError, "cable down")
      expect {
        described_class.broadcast({ session_id: 7, step_id: 3, text: "x" })
      }.not_to raise_error
    end
  end
end
