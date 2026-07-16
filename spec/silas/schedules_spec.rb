require "rails_helper"
require "tmpdir"

RSpec.describe "schedules" do
  include ActiveJob::TestHelper

  before { Silas::Registry.install!(root: DummyApp.root) }

  describe Silas::Registry do
    it "discovers schedules by filesystem identity (subdirs included), sorted" do
      names = Silas.schedules.map(&:name)
      expect(names).to eq(%w[billing/sweep daily_digest])
    end

    it "keeps schedules out of the definitions digest" do
      before_digest = described_class.new(root: DummyApp.root).digest
      # A schedule is a trigger, not a model-visible capability: the digest that
      # guards mid-turn determinism must not move when schedules change.
      expect(Silas.tool_definitions.map { |d| d["name"] }).not_to include("daily_digest")
      expect(before_digest).to eq(described_class.new(root: DummyApp.root).digest)
    end
  end

  describe Silas::Schedule do
    let(:by_name) { Silas.schedules.index_by(&:name) }

    it "parses a .md task schedule" do
      s = by_name.fetch("daily_digest")
      expect(s.kind).to eq(:task)
      expect(s.cron).to eq("0 9 * * *")
      expect(s.payload).to include("support tickets")
      expect(s.recurring_key).to eq("silas_schedule_daily_digest")
    end

    it "parses a .rb handler schedule with the DSL" do
      s = by_name.fetch("billing/sweep")
      expect(s.kind).to eq(:handler)
      expect(s.cron).to eq("0 2 * * *")
      expect(s.queue).to eq("low")
      expect(s.payload).to eq(Agent::Schedules::Billing::Sweep)
      expect(s.recurring_key).to eq("silas_schedule_billing_sweep")
    end

    it "raises on a .md with no cron frontmatter" do
      Dir.mktmpdir do |dir|
        path = Pathname(dir).join("app/agent/schedules/x.md")
        path.dirname.mkpath
        path.write("no frontmatter here")
        expect { described_class.parse(path, root: Pathname(dir)) }
          .to raise_error(Silas::Error, /missing `cron:`/)
      end
    end
  end

  describe Silas::Schedule::Compiler do
    let(:schedules) { Silas.schedules }

    it "renders deterministic recurring entries" do
      rendered = described_class.render(schedules)
      expect(rendered["silas_schedule_daily_digest"]).to eq(
        "class" => "Silas::ScheduleJob", "args" => [ "daily_digest" ],
        "schedule" => "0 9 * * *", "queue" => "default"
      )
      expect(rendered["silas_schedule_billing_sweep"]["queue"]).to eq("low")
    end

    it "merges managed entries while preserving hand-written ones, idempotently" do
      Dir.mktmpdir do |dir|
        root = Pathname(dir)
        recurring = root.join("config/recurring.yml")
        recurring.dirname.mkpath
        recurring.write(<<~YAML)
          production:
            silas_dead_job_rescuer:
              class: Silas::DeadJobRescuerJob
              schedule: every 30 seconds
        YAML

        described_class.write!(schedules, root: root)
        described_class.write!(schedules, root: root) # twice — must be idempotent

        doc = YAML.safe_load(recurring.read).fetch("production")
        expect(doc.keys).to contain_exactly(
          "silas_dead_job_rescuer", "silas_schedule_daily_digest", "silas_schedule_billing_sweep"
        )
        expect(doc["silas_dead_job_rescuer"]["class"]).to eq("Silas::DeadJobRescuerJob")
      end
    end

    it "reports drift (uncompiled files, orphaned entries)" do
      Dir.mktmpdir do |dir|
        root = Pathname(dir)
        root.join("config").mkpath
        root.join("config/recurring.yml").write(YAML.dump(
          "production" => { "silas_schedule_ghost" => { "class" => "Silas::ScheduleJob" } }
        ))
        drift = described_class.drift(schedules, root: root)
        expect(drift[:uncompiled]).to contain_exactly("daily_digest", "billing/sweep")
        expect(drift[:orphaned]).to eq([ "silas_schedule_ghost" ])
      end
    end
  end

  describe Silas::ScheduleJob do
    def with_fake_engine
      Silas.configure do |c|
        c.engine = FakeEngine.new(&EngineScripts.n_tool_steps_then_done(0))
        c.isolate_steps = false
      end
      Silas::Registry.install!(root: DummyApp.root)
    end

    it "task mode: starts a durable turn whose input is the schedule body" do
      with_fake_engine
      expect { Silas::ScheduleJob.perform_now("daily_digest") }.to change(Silas::Session, :count).by(1)

      session = Silas::Session.last
      expect(session.metadata).to eq("trigger" => "schedule", "schedule" => "daily_digest")
      turn = session.turns.sole
      expect(turn.input).to include("support tickets")
      expect(turn.status).to eq("queued")

      perform_enqueued_jobs
      expect(turn.reload.status).to eq("completed")
    end

    it "handler mode: runs the handler with its schedule" do
      with_fake_engine
      Agent::Schedules::Billing::Sweep.runs.clear
      Silas::ScheduleJob.perform_now("billing/sweep")
      expect(Agent::Schedules::Billing::Sweep.runs).to eq([ "billing/sweep" ])
    end

    it "no-ops (no raise) on a stale schedule name whose file is gone" do
      with_fake_engine
      expect { Silas::ScheduleJob.perform_now("deleted_schedule") }
        .not_to change(Silas::Session, :count)
    end
  end
end
