require "rails_helper"

RSpec.describe Silas::Tool do
  describe "declaration inheritance" do
    # Ruby does not inherit class-level instance variables. Factoring shared
    # declarations into a base class is ordinary Rails practice, and before this
    # was fixed it silently dropped BOTH ledger-visible declarations into their
    # least safe defaults: no transaction, no approval gate.
    let(:base) do
      Class.new(described_class) do
        description "Money movement."
        param :amount_pence, :integer, desc: "Pence"
        approval :always
        transactional!

        def call(amount_pence:) = { moved: amount_pence }
      end
    end

    it "inherits effect mode — a subclass of a transactional! base is not silently downgraded" do
      subclass = Class.new(base)
      expect(subclass.effect_mode).to eq(:transactional)
    end

    it "inherits the approval policy — a subclass of an approval :always base is not silently disarmed" do
      subclass = Class.new(base)
      expect(subclass.approval_policy).to eq(:always)
    end

    it "inherits description and param refinements into the schema" do
      subclass = Class.new(base) { def self.tool_name = "sub" }
      schema = subclass.schema

      expect(schema["description"]).to eq("Money movement.")
      expect(schema["input_schema"]["properties"]["amount_pence"])
        .to eq({ "type" => "integer", "description" => "Pence" })
    end

    it "inherits a lambda approval policy" do
      gated = Class.new(described_class) do
        approval ->(session:, input:) { input[:amount_pence] > 2_500 ? :user_approval : :approved }
        def call(amount_pence:) = {}
      end
      subclass = Class.new(gated)

      expect(subclass.approval_policy).to be_a(Proc)
      expect(subclass.approval_policy.call(session: nil, input: { amount_pence: 5_000 })).to eq(:user_approval)
    end

    it "lets a subclass override the inherited declarations" do
      subclass = Class.new(base) do
        approval :never
        idempotent!
      end

      expect(subclass.effect_mode).to eq(:idempotent)
      expect(subclass.approval_policy).to eq(:never)
      # ...without disturbing the base
      expect(base.effect_mode).to eq(:transactional)
      expect(base.approval_policy).to eq(:always)
    end

    it "lets a subclass override one inherited param while keeping the others" do
      multi = Class.new(described_class) do
        param :amount_pence, :integer
        param :note, :string
        def call(amount_pence:, note:) = {}
      end
      subclass = Class.new(multi) do
        param :note, :integer
        def self.tool_name = "sub"
      end

      props = subclass.schema["input_schema"]["properties"]
      expect(props["amount_pence"]["type"]).to eq("integer")
      expect(props["note"]["type"]).to eq("integer")
    end

    it "resolves through a two-level ancestry" do
      middle = Class.new(base)
      leaf = Class.new(middle)

      expect(leaf.effect_mode).to eq(:transactional)
      expect(leaf.approval_policy).to eq(:always)
    end

    it "still defaults a direct subclass that declares nothing" do
      bare = Class.new(described_class) { def call = {} }

      expect(bare.effect_mode).to eq(:at_most_once)
      expect(bare.approval_policy).to eq(:never)
      expect(bare.description).to eq("")
    end

    it "delegates the inherited values instance-side, which is what the Ledger reads" do
      instance = Class.new(base).new

      expect(instance.effect_mode).to eq(:transactional)
      expect(instance.approval_policy).to eq(:always)
    end
  end
end
