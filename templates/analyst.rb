# coding: utf-8

# Silas application template — the analyst:
#
#   rails new analyst -m https://raw.githubusercontent.com/danielstpaul/silas/main/templates/analyst.rb
#
# A reporting agent over a small metrics table: reads move freely, anomalies
# are flagged as rows (exactly-once), and PUBLISHING anything holds at the
# signal until a person clears it. Ships a Monday-morning schedule, a
# schema-checked structured answer, a keyless scripted demo, deterministic
# evals, and a signal-board landing page. Requires Rails >= 8.1.
#
# CI note: SILAS_PATH=/path/to/checkout uses a local silas instead of the
# released gem (the templates_smoke workflow verifies every template this way).

# Locale-less environments (some docker/CI shells) leave Ruby's external
# encoding at US-ASCII, which breaks Thor's file mutations on any file
# containing UTF-8. Everything this template touches is UTF-8.
Encoding.default_external = Encoding::UTF_8 if Encoding.default_external == Encoding::US_ASCII

if (silas_path = ENV["SILAS_PATH"])
  gem "silas", path: silas_path
else
  gem "silas"
end

after_bundle do
  # ── Silas itself ─────────────────────────────────────────────────────────
  generate "silas:install"

  # ── The analyst: one agent, three tools, one per effect mode ─────────────
  remove_file "app/agent/tools/example_tool.rb"

  create_file "app/agent/instructions.md", force: true do
    <<~'MD'
      # The analyst

      You are the in-house analyst for a small goods shop. You report on the
      metrics table and nothing else.

      Rules:

      - Always query the metrics before stating any number. Never quote a
        figure a tool didn't return.
      - Compare week over week. Call out any metric that moved more than 20%
        — and flag it with flag_anomaly so it's on the record.
      - Publishing a report is consequential: publish_report HOLDS until an
        operator clears it. That's expected — say the report is awaiting
        clearance, never that something failed.
      - Keep digests to five lines. Numbers in pounds and pence.
    MD
  end

  create_file "app/agent/agent.yml", force: true do
    <<~'YAML'
      # Data-only agent config. Model defaults to Silas.config.default_model.
      # model: claude-sonnet-4-5
      description: The analyst — reads the metrics, flags anomalies, publishes digests (held for clearance).
      limits:
        max_steps: 8      # model calls per turn
        max_cost: 0.25    # dollars per turn
        timeout: 300      # seconds of ACTIVE work — held time doesn't count

      # Structured final answers: the turn's verdict comes back as a Hash on
      # Turn#answer_data (and over the API as answer_data), schema-checked.
      final_answer:
        type: object
        properties:
          verdict: { type: string }
          wow_delta: { type: string }
        required: [verdict]
    YAML
  end

  create_file "app/agent/tools/query_metrics.rb" do
    <<~'RUBY'
      # Tool identity is the filename: this is the "query_metrics" tool.
      # The keyword signature of #call IS the schema the model sees.
      class Agent::Tools::QueryMetrics < Silas::Tool
        description "Read daily metrics, newest first (revenue_pence, refunds_pence, orders)."
        param :days, :integer, desc: "How many days back to read (default 14)"
        idempotent! # read-only, so crash replays may re-run it freely

        def call(metric: nil, days: 14)
          rows = Metric.where(recorded_on: days.days.ago.to_date..)
          rows = rows.where(name: metric.to_s) if metric
          return { error: "no metrics recorded" } if rows.none?

          { metrics: rows.order(recorded_on: :desc).map do |m|
            { name: m.name, value: m.value, recorded_on: m.recorded_on.iso8601 }
          end }
        end
      end
    RUBY
  end

  create_file "app/agent/tools/flag_anomaly.rb" do
    <<~'RUBY'
      # transactional!: the anomaly row and the ledger's "this ran" record
      # commit in ONE database transaction — exactly-once, even through
      # kill -9. Right here because the effect lives in this app's own tables.
      class Agent::Tools::FlagAnomaly < Silas::Tool
        description "Put an unusual metric movement on the record."
        transactional!

        def call(metric:, recorded_on:, note:)
          anomaly = Anomaly.find_or_create_by!(metric: metric.to_s, recorded_on: Date.parse(recorded_on.to_s)) do |a|
            a.note = note
          end
          { flagged: anomaly.metric, recorded_on: anomaly.recorded_on.iso8601, anomaly_id: anomaly.id }
        end
      end
    RUBY
  end

  create_file "app/agent/tools/publish_report.rb" do
    <<~'RUBY'
      # Publishing leaves the building, so it's at_most_once! (a crash that
      # makes "did it post?" ambiguous parks IN DOUBT for a human) and it
      # ALWAYS holds for clearance first — nothing posts until a person
      # clears it. Swap the body for your real Slack/email transport.
      class Agent::Tools::PublishReport < Silas::Tool
        description "Publish a finished digest to a channel."
        approval :always
        at_most_once!

        def call(channel:, body:)
          # Stand-in transport: replace with your Slack/mailer call.
          Rails.logger.info("[analyst] publish to=#{channel}: #{body}")
          { posted: true, channel: channel }
        end
      end
    RUBY
  end

  create_file "app/agent/schedules/monday_kpis.md" do
    <<~'MD'
      ---
      cron: "0 7 * * 1"
      ---
      Pull the last 14 days of metrics, compute week-over-week deltas for
      revenue, refunds, and orders, flag anything that moved more than 20%,
      and publish the Monday digest to #metrics.
    MD
  end

  # ── Domain: a small metrics table + anomalies ────────────────────────────
  # Fixed past timestamp: a generation-time stamp can land in the same second
  # as the silas migrations the installer copies, colliding on version number.
  create_file "db/migrate/20260101000000_create_metrics.rb" do
    <<~'RUBY'
      class CreateMetrics < ActiveRecord::Migration[8.1]
        def change
          create_table :metrics do |t|
            t.string :name, null: false
            t.integer :value, null: false
            t.date :recorded_on, null: false
            t.timestamps
          end
          add_index :metrics, [:name, :recorded_on], unique: true

          create_table :anomalies do |t|
            t.string :metric, null: false
            t.date :recorded_on, null: false
            t.string :note
            t.timestamps
          end
          add_index :anomalies, [:metric, :recorded_on], unique: true
        end
      end
    RUBY
  end

  create_file "app/models/metric.rb" do
    <<~'RUBY'
      class Metric < ApplicationRecord
      end
    RUBY
  end

  create_file "app/models/anomaly.rb" do
    <<~'RUBY'
      class Anomaly < ApplicationRecord
      end
    RUBY
  end

  append_to_file "db/seeds.rb" do
    <<~'RUBY'
      # Two deterministic weeks: revenue up ~4%, orders steady, and a refunds
      # spike five days ago for the agent to find.
      revenue = [ 178_00, 181_00, 175_00, 190_00, 186_00, 179_00, 183_00,
                  184_00, 188_00, 181_00, 196_00, 193_00, 187_00, 191_00 ]
      refunds = [ 6_00, 4_00, 5_00, 7_00, 5_00, 6_00, 4_00,
                  5_00, 6_00, 27_00, 5_00, 4_00, 6_00, 5_00 ]
      orders  = [ 21, 22, 20, 24, 23, 21, 22, 22, 23, 21, 25, 24, 22, 23 ]

      { "revenue_pence" => revenue, "refunds_pence" => refunds, "orders" => orders }.each do |name, series|
        series.each_with_index do |value, i|
          date = Date.current - (series.size - 1 - i)
          Metric.find_or_create_by!(name: name, recorded_on: date) { |m| m.value = value }
        end
      end
    RUBY
  end

  # ── Keyless demo: a scripted stand-in when no provider key is set ────────
  create_file "lib/demo_adapter.rb" do
    <<~'RUBY'
      class DemoAdapter < Silas::Adapters::Base
        def execute_step(context, &on_event)
          input = context[:turn].input.to_s.downcase
          index = context[:index]

          if input.include?("digest") || input.include?("monday") || input.include?("publish")
            digest_story(index, &on_event)
          elsif input.include?("anomal") || input.include?("refund")
            read_story(index, &on_event)
          else
            say("(Keyless demo — I'm a scripted stand-in, not a model. Ask for " \
                "\"the Monday digest\" to watch a report get built, an anomaly " \
                "flagged exactly once, and publish_report HOLD at the signal " \
                "until you clear it in /silas/inbox. Ask \"any anomalies?\" for " \
                "a read-only pass. Set ANTHROPIC_API_KEY and restart to talk " \
                "to a real model.)", &on_event)
          end
        end

        private

        # The full Monday run: read, flag the refunds spike (exactly-once row),
        # then publish — which HOLDS until an operator clears it.
        def digest_story(index, &on_event)
          case index
          when 0 then tool("query_metrics", { "days" => 14 })
          when 1 then tool("flag_anomaly", { "metric" => "refunds_pence",
                                             "recorded_on" => (Date.current - 4).iso8601,
                                             "note" => "refunds 5x the daily norm" })
          when 2 then tool("publish_report", { "channel" => "#metrics",
                                               "body" => "Revenue £191.00 (+4.2% WoW). Orders steady. One refunds spike (£27.00), flagged." })
          else answer("verdict" => "revenue improving; the refunds spike was flagged and the digest is published",
                      "wow_delta" => "+4.2%")
          end
        end

        # Read-only: nothing to clear, the turn just answers.
        def read_story(index, &on_event)
          case index
          when 0 then tool("query_metrics", { "metric" => "refunds_pence", "days" => 14 })
          else answer("verdict" => "one refunds spike four days ago (£27.00, ~5x the daily norm); otherwise steady",
                      "wow_delta" => "-2.1%")
          end
        end

        def tool(name, arguments)
          sleep 0.7 # presentation cadence — a real model call takes a second or two
          Silas::Adapters::Result.new(
            blocks: [],
            tool_calls: [ Silas::Adapters::ToolCall.new(id: "demo_#{name}", name: name, arguments: arguments) ],
            stop_reason: "tool_use",
            usage: { input_tokens: 40, output_tokens: 15 }
          )
        end

        # The schema-checked case: the same {"type"=>"structured"} block the
        # real adapter persists when agent.yml declares final_answer — read
        # back through Turn#answer_data, rendered as a data card in the inbox.
        def answer(data)
          Silas::Adapters::Result.new(
            blocks: [ { "type" => "structured", "data" => data } ],
            tool_calls: [], stop_reason: "end_turn",
            usage: { input_tokens: 60, output_tokens: 30 }
          )
        end

        def say(text, &on_event)
          text.chars.each_slice(3) do |chunk|
            on_event&.call(Silas::Event.new(type: :text_delta, payload: { text: chunk.join }))
            sleep 0.02
          end
          Silas::Adapters::Result.new(
            blocks: [ { "type" => "text", "text" => text } ],
            tool_calls: [], stop_reason: "end_turn",
            usage: { input_tokens: 60, output_tokens: text.length / 4 }
          )
        end
      end
    RUBY
  end

  inject_into_file "config/initializers/silas.rb", after: "config.adapter = :ruby_llm\n" do
    <<-'RUBY'

  # Keyless first run: with no provider key in development/test, a scripted
  # stand-in drives the analyst (lib/demo_adapter.rb) - the tools, ledger,
  # and holds are all real. Set ANTHROPIC_API_KEY to use a real model.
  if Rails.env.local? && ENV["ANTHROPIC_API_KEY"].to_s.empty?
    require Rails.root.join("lib/demo_adapter")
    config.adapter = DemoAdapter.new
  end
    RUBY
  end

  inject_into_file "config/initializers/silas.rb",
                   after: "# config.inbox_public_read = true   # read-only demo mode; writes stay gated\n" do
    <<-'RUBY'

  # Starter default: the inbox is OPEN in development only; everywhere else it
  # stays deny-by-default (404). Wire real auth before deploying.
  config.inbox_auth = ->(controller) { controller.head :not_found unless Rails.env.development? }
    RUBY
  end

  # ── Solid Queue + Solid Cable in development ─────────────────────────────
  gsub_file "config/database.yml",
            "development:\n  <<: *default\n  database: storage/development.sqlite3\n",
            <<~YAML
              development:
                primary:
                  <<: *default
                  database: storage/development.sqlite3
                queue:
                  <<: *default
                  database: storage/development_queue.sqlite3
                  migrations_paths: db/queue_migrate
                cable:
                  <<: *default
                  database: storage/development_cable.sqlite3
                  migrations_paths: db/cable_migrate
            YAML

  gsub_file "config/database.yml",
            "test:\n  <<: *default\n  database: storage/test.sqlite3\n",
            <<~YAML
              test:
                primary:
                  <<: *default
                  database: storage/test.sqlite3
                queue:
                  <<: *default
                  database: storage/test_queue.sqlite3
                  migrations_paths: db/queue_migrate
                cable:
                  <<: *default
                  database: storage/test_cable.sqlite3
                  migrations_paths: db/cable_migrate
            YAML

  environment <<~'RUBY', env: "development"
    # Solid Queue in development too, deliberately: Silas's durability
    # contract needs a real worker (never :async). Run it with bin/dev.
    config.active_job.queue_adapter = :solid_queue
    config.solid_queue.connects_to = { database: { writing: :queue } }
  RUBY

  create_file "config/cable.yml", force: true do
    <<~'YAML'
      # solid_cable in development too, deliberately: Silas emits token deltas
      # from the Solid Queue WORKER process, and the async adapter is
      # single-process — the browser would never see them.
      development:
        adapter: solid_cable
        connects_to:
          database:
            writing: cable
        polling_interval: 0.1.seconds
        message_retention: 1.day

      test:
        adapter: test

      production:
        adapter: solid_cable
        connects_to:
          database:
            writing: cable
        polling_interval: 0.1.seconds
        message_retention: 1.day
    YAML
  end

  create_file "Procfile.dev", force: true do
    <<~'PROCFILE'
      web: bin/rails server
      jobs: bin/jobs
    PROCFILE
  end

  create_file "bin/dev", force: true do
    <<~'SH'
      #!/usr/bin/env sh

      if ! gem list foreman -i --silent; then
        echo "Installing foreman..."
        gem install foreman
      fi

      # Default to port 3000 if not specified
      export PORT="${PORT:-3000}"

      # Let the debug gem allow remote connections,
      # but avoid loading until `debugger` is called
      export RUBY_DEBUG_OPEN="true"
      export RUBY_DEBUG_LAZY="true"

      # `gem exec` resolves foreman from the gem store directly — no PATH, no
      # shim, no `asdf reshim` needed after the install above.
      exec gem exec foreman start -f Procfile.dev "$@"
    SH
  end
  chmod "bin/dev", 0o755

  # ── Production deploy: the agent needs its key ───────────────────────────
  if File.exist?("config/deploy.yml")
    inject_into_file "config/deploy.yml", after: /^\s*secret:\s*\n\s*- RAILS_MASTER_KEY\n/ do
      "    - ANTHROPIC_API_KEY\n"
    end
  end
  if File.exist?(".kamal/secrets")
    append_to_file ".kamal/secrets", "\nANTHROPIC_API_KEY=$ANTHROPIC_API_KEY\n"
  end

  # ── Evals: the model's decisions scripted, the real ledger asserted ──────
  remove_file "test/agent_evals/example_eval.rb"
  create_file "test/agent_evals/analyst_eval.rb" do
    <<~'RUBY'
      # Deterministic evals: the MODEL's decisions are scripted, but the real
      # Ledger runs the real tools against the real tables. Run:
      # bin/rails db:seed silas:eval  (bin/ci gates on them).

      Silas::Eval.scenario "read-only pass never holds" do
        input "Any anomalies in refunds this week?"

        on_step 0, call: { name: "query_metrics", arguments: { metric: "refunds_pence", days: 14 } }
        on_step 1, data: { verdict: "one refunds spike (£27.00), otherwise steady", wow_delta: "-2.1%" }

        expect do
          assert_turn_completed
          assert_tool_called "query_metrics", times: 1
          assert_no_tool_called "publish_report"
          assert_answer_data { |d| d["verdict"].include?("spike") }
        end
      end

      Silas::Eval.scenario "publishing holds at the signal" do
        input "Run the Monday digest."

        on_step 0, call: { name: "query_metrics", arguments: { days: 14 } }
        on_step 1, call: { name: "publish_report",
                           arguments: { channel: "#metrics", body: "Revenue up 4.2% WoW; refunds spiked once." } }

        expect do
          # Publishing is gated: the turn holds at zero compute and nothing
          # posted. The no-surprise-sends guarantee, asserted.
          assert_parked tool: "publish_report"
          assert_no_tool_called "publish_report"
        end
      end

      Silas::Eval.scenario "cleared: flags exactly once, publishes exactly once" do
        input "Run the Monday digest."

        on_step 0, call: { name: "flag_anomaly",
                           arguments: { metric: "refunds_pence", recorded_on: "2026-01-05", note: "5x daily norm" } }
        on_step 1, call: { name: "publish_report",
                           arguments: { channel: "#metrics", body: "Revenue up 4.2% WoW; one refunds spike, flagged." } }
        on_step 2, data: { verdict: "digest published to #metrics", wow_delta: "+4.2%" }

        approve tool: "publish_report"   # the same approve! as the inbox and Slack

        expect do
          assert_turn_completed
          assert_approved tool: "publish_report"
          assert_tool_called "flag_anomaly", times: 1     # exactly-once row
          assert_tool_called "publish_report", times: 1   # exactly once, across the hold
          assert_answer_data(key: :wow_delta, value: "+4.2%")
        end
      end
    RUBY
  end

  if File.exist?("config/ci.rb")
    inject_into_file "config/ci.rb", "  step \"Agent evals\", \"bin/rails db:seed silas:eval\"\n",
                     before: /^end\s*\z/
  end

  # ── A smoke test for the web surface ─────────────────────────────────────
  create_file "test/integration/home_test.rb" do
    <<~'RUBY'
      require "test_helper"

      class HomeTest < ActionDispatch::IntegrationTest
        test "the signal board renders" do
          get "/"
          assert_response :success
          assert_includes response.body, "silas"
          assert_includes response.body, "held"
        end
      end
    RUBY
  end

  # ── The landing page: a signal board for the analyst ─────────────────────
  route 'root "home#show"'

  create_file "app/controllers/home_controller.rb" do
    <<~'RUBY'
      class HomeController < ApplicationController
        def show
          @model = agent_model
          @tools = Dir[Rails.root.join("app/agent/tools/*.rb")].map { |f| File.basename(f, ".rb") }.sort
          @counts = Silas::Turn.group(:status).count
          @sessions = Silas::Session.count
          @demo = defined?(DemoAdapter) && Silas.config.adapter.is_a?(DemoAdapter)
        end

        private

        def agent_model
          YAML.safe_load_file(Rails.root.join("app/agent/agent.yml"))["model"] || Silas.config.default_model
        rescue StandardError
          Silas.config.default_model
        end
      end
    RUBY
  end

  create_file "app/views/home/show.html.erb" do
    <<~'ERB'
      <%# The signal board — brand direction "Signals": dark-first, one white
          lamp as the accent (never a status), aspect colours for state. %>
      <style>
        :root {
          --bg: #0F1013; --panel: #16181D; --ink: #E9EBEF; --muted: #969CA8;
          --line: #262A33; --grey-bg: #1D2027;
          --accent: #F2F4F8; --accent-soft: #1D2027;
          --blue: #58A6FF;   --blue-bg: #14233D;
          --amber: #E3B341;  --amber-bg: #2E2611;
          --violet: #B49AE8; --violet-bg: #241E33;
          --green: #3FB950;  --green-bg: #12291B;
          --red: #F85149;    --red-bg: #331815;
          --quiet: #737A87;  --quiet-line: #4A5160;
          --radius: 8px;
          --sans: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
          --sans-display: Archivo, "Helvetica Neue", Helvetica, Arial, sans-serif;
          --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
        }
        @media (prefers-color-scheme: light) {
          :root {
            --bg: #F4F4F2; --panel: #FFFFFF; --ink: #15171B; --muted: #5B5F68;
            --line: #DCDEE3; --grey-bg: #EDEEF1;
            --accent: #274FBF; --accent-soft: #E3E9FA;
            --blue: #1D4ED8;   --blue-bg: #DCE7F5;
            --amber: #92650E;  --amber-bg: #FBEED0;
            --violet: #63459B; --violet-bg: #EAE3F7;
            --green: #157A3D;  --green-bg: #DCF3E3;
            --red: #B91C1C;    --red-bg: #FBDCDA;
            --quiet: #5B5F68;  --quiet-line: #C7CAD1;
          }
        }
        html { background: var(--bg); }
        body { margin: 0; background: var(--bg); color: var(--ink);
               font-family: var(--sans); -webkit-font-smoothing: antialiased; }
        .wrap { max-width: 780px; margin: 0 auto; padding: 28px 20px 64px; }
        header.board { display: flex; align-items: center; gap: 10px; padding-bottom: 22px; }
        header.board .logo { font-family: var(--sans-display); font-weight: 800;
                             font-size: 20px; letter-spacing: -0.03em; }
        header.board .mark .bezel { stroke: var(--ink); }
        header.board .mark .lamp { fill: var(--accent); }
        header.board nav { margin-left: auto; }
        a { color: var(--accent); text-underline-offset: 2px; }
        h1 { font-family: var(--sans-display); font-weight: 800; letter-spacing: -0.02em;
             font-size: 34px; margin: 18px 0 8px; }
        .sub { color: var(--muted); margin: 0 0 26px; max-width: 56ch; line-height: 1.5; }
        .board-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 10px; }
        @media (max-width: 560px) { .board-grid { grid-template-columns: repeat(2, 1fr); } }
        .aspect { border-radius: var(--radius); padding: 14px 14px 12px; }
        .aspect .n { font-family: var(--mono); font-size: 26px; font-weight: 700; display: block; }
        .aspect .l { font-size: 12px; letter-spacing: 0.04em; text-transform: uppercase; }
        .aspect.held    { background: var(--amber-bg);  color: var(--amber); }
        .aspect.working { background: var(--blue-bg);   color: var(--blue); }
        .aspect.clear   { background: var(--green-bg);  color: var(--green); }
        .aspect.doubt   { background: var(--violet-bg); color: var(--violet); }
        .quietline { color: var(--quiet); font-size: 13px; margin: 10px 2px 0; }
        .card { background: var(--panel); border: 1px solid var(--line);
                border-radius: var(--radius); padding: 18px 18px 16px; margin-top: 22px; }
        .card h2 { font-size: 13px; letter-spacing: 0.05em; text-transform: uppercase;
                   color: var(--muted); margin: 0 0 12px; font-weight: 600; }
        .row { display: flex; gap: 12px; padding: 7px 0; border-top: 1px solid var(--line);
               font-size: 14px; align-items: baseline; }
        .row:first-of-type { border-top: 0; }
        .row .k { color: var(--muted); width: 96px; flex-shrink: 0; }
        .chip { font-family: var(--mono); font-size: 12.5px; background: var(--grey-bg);
                border: 1px solid var(--line); border-radius: 6px; padding: 2px 8px;
                margin-right: 6px; display: inline-block; margin-bottom: 4px; }
        .demo { background: var(--amber-bg); color: var(--amber); border-radius: var(--radius);
                padding: 14px 16px; margin-top: 22px; font-size: 14px; line-height: 1.55; }
        .demo strong { letter-spacing: 0.04em; text-transform: uppercase; font-size: 12px; }
        .try { list-style: none; margin: 0; padding: 0; }
        .try li { padding: 8px 0; border-top: 1px solid var(--line); }
        .try li:first-child { border-top: 0; }
        .try code { font-family: var(--mono); font-size: 13.5px; }
        .try .fate { color: var(--muted); font-size: 12.5px; display: block; margin-top: 2px; }
        .cta { display: flex; gap: 12px; margin-top: 26px; align-items: center; flex-wrap: wrap; }
        .btn { background: var(--accent); color: var(--bg); border-radius: var(--radius);
               padding: 10px 18px; font-weight: 600; text-decoration: none; font-size: 15px; }
        .cta code { font-family: var(--mono); font-size: 13px; color: var(--muted); }
        footer { margin-top: 40px; color: var(--quiet); font-size: 13px;
                 border-top: 1px solid var(--line); padding-top: 16px; line-height: 1.6; }
      </style>

      <div class="wrap">
        <header class="board">
          <svg class="mark" width="24" height="24" viewBox="0 0 24 24" fill="none" role="img" aria-label="Silas">
            <circle class="bezel" cx="12" cy="12" r="9.6" fill="none" stroke-width="2.2"/>
            <circle class="lamp" cx="8.61" cy="15.39" r="2.5"/>
            <circle class="lamp" cx="15.39" cy="8.61" r="2.5"/>
          </svg>
          <span class="logo">silas</span>
          <nav><a href="<%= silas.inbox_root_path %>">operator inbox →</a></nav>
        </header>

        <h1>The analyst is in.</h1>
        <p class="sub">
          A reporting agent runs inside this app. Reads move freely, anomalies
          land as rows exactly once — and nothing gets published until you
          clear it at the signal.
        </p>

        <div class="board-grid">
          <a class="aspect held" href="<%= silas.inbox_root_path(pending: 1) %>" style="text-decoration:none">
            <span class="n"><%= @counts.fetch("waiting", 0) %></span><span class="l">held</span>
          </a>
          <div class="aspect working">
            <span class="n"><%= @counts.fetch("running", 0) + @counts.fetch("queued", 0) %></span><span class="l">working</span>
          </div>
          <div class="aspect clear">
            <span class="n"><%= @counts.fetch("completed", 0) %></span><span class="l">clear</span>
          </div>
          <div class="aspect doubt">
            <span class="n"><%= @counts.fetch("in_doubt", 0) %></span><span class="l">in doubt</span>
          </div>
        </div>
        <% failed = @counts.fetch("failed", 0); canceled = @counts.fetch("canceled", 0) %>
        <% if failed.positive? || canceled.positive? %>
          <p class="quietline"><%= failed %> failed · <%= canceled %> canceled · <%= @sessions %> sessions</p>
        <% else %>
          <p class="quietline"><%= @sessions %> <%= "session".pluralize(@sessions) %> so far</p>
        <% end %>

        <% if @demo %>
          <div class="demo">
            <strong>keyless demo</strong> — a scripted stand-in is driving the
            analyst. The tools, the ledger, and the hold are all real; only the
            model's decisions are canned. Set <code>ANTHROPIC_API_KEY</code> and
            restart to talk to a real model.
          </div>
        <% end %>

        <div class="card">
          <h2>This agent</h2>
          <div class="row"><span class="k">model</span>
            <span><%= @demo ? "scripted stand-in (no key set)" : @model %></span></div>
          <div class="row"><span class="k">tools</span>
            <span><% @tools.each do |t| %><code class="chip"><%= t %></code><% end %></span></div>
          <div class="row"><span class="k">the gate</span>
            <span>publish_report holds for a person — nothing posts until you clear it in the inbox</span></div>
          <div class="row"><span class="k">the clock</span>
            <span><code class="chip">schedules/monday_kpis.md</code> — Mondays 07:00, a normal durable turn</span></div>
          <div class="row"><span class="k">defined in</span>
            <span><code class="chip">app/agent/</code> — instructions, tools, schedules. The directory is the agent.</span></div>
        </div>

        <div class="card">
          <h2>Try it — start a session in the inbox</h2>
          <ul class="try">
            <li>
              <code>Run the Monday digest.</code>
              <span class="fate">reads two weeks, flags the refunds spike exactly once, then publishing HOLDS — watch the amber card.</span>
            </li>
            <li>
              <code>Any anomalies in refunds this week?</code>
              <span class="fate">read-only: answers with a schema-checked verdict, nothing to clear.</span>
            </li>
            <li>
              <code>bin/rails silas:chat</code>
              <span class="fate">the same analyst, from your terminal.</span>
            </li>
          </ul>
        </div>

        <div class="cta">
          <a class="btn" href="<%= silas.inbox_root_path %>">Open the inbox</a>
          <code>bin/ci · tests + agent evals, keyless</code>
        </div>

        <footer>
          Held at the signal until you clear it. Built on
          <a href="https://github.com/danielstpaul/silas">silas <%= Silas::VERSION %></a> —
          durable agents for Rails: exactly-once tools, human gates, crash-safe turns.<br>
          Deep docs ship in the gem: <code>bundle show silas</code> → README, docs/, DEPLOY.md.
        </footer>
      </div>
    ERB
  end

  # ── README for the generated app ─────────────────────────────────────────
  create_file "README.md", force: true do
    <<~'MD'
      # The analyst

      An agent app built on [Silas](https://github.com/danielstpaul/silas) —
      durable AI agents for Rails. A reporting agent runs inside it: it reads a
      small metrics table, flags anomalies as rows (**exactly once**, even
      through a crash), and **nothing gets published until a person clears it
      at the signal**. Mondays at 07:00 it runs itself.

      ## First run — no API key needed

      ```sh
      bin/setup
      bin/dev        # web + the Solid Queue worker (the durability contract needs both)
      ```

      Open <http://localhost:3000> — the signal board — then start a session in
      the inbox:

      | prompt | what happens |
      |---|---|
      | `Run the Monday digest.` | Reads two weeks of metrics, flags the refunds spike, then `publish_report` **holds** — clear it from the amber card and the turn resumes exactly where it stopped. |
      | `Any anomalies in refunds this week?` | Read-only — answers with a schema-checked verdict (`Turn#answer_data`). |

      With no `ANTHROPIC_API_KEY` set, a scripted stand-in plays the model —
      the tools, ledger, and hold are all real. Export a key and restart to
      talk to a real model.

      ## The agent is a directory

      ```
      app/agent/
        instructions.md          # persona
        agent.yml                # model + limits + the final_answer schema
        tools/
          query_metrics.rb       # idempotent!     — read-only, replays freely
          flag_anomaly.rb        # transactional!  — DB effect: exactly-once
          publish_report.rb      # at_most_once! + approval :always — nothing posts uncleared
        schedules/
          monday_kpis.md         # cron "0 7 * * 1" -> a normal durable turn
      ```

      ## Tests and evals — keyless, deterministic

      ```sh
      bin/ci                       # app tests + agent evals
      bin/rails db:seed silas:eval # just the evals
      ```

      Evals script the **model's decisions** and assert on the **real ledger**:
      publishing holds, the anomaly row lands exactly once across the hold, and
      the structured verdict comes back schema-checked. See
      `test/agent_evals/analyst_eval.rb`.

      ## Going live

      1. `ANTHROPIC_API_KEY` in production (already listed in `config/deploy.yml`'s secrets).
      2. Replace the dev-only inbox auth in `config/initializers/silas.rb`.
      3. `bin/rails silas:schedules` after editing any schedule.
      4. `bin/rails silas:doctor`, then deploy with Kamal as usual — the deep
         guide ships in the gem: `bundle show silas` → `DEPLOY.md`.

      Swap the metrics table for your own domain whenever you're ready — the
      shape stays: read freely, write exactly once, publish only past the gate.
    MD
  end

  # ── Databases ready + seeded ─────────────────────────────────────────────
  rails_command "db:prepare"
  rails_command "db:seed"

  say ""
  say "──────────────────────────────────────────────────────────", :green
  say "The analyst is in.", :green
  say ""
  say "  cd #{app_name}"
  say "  bin/dev                → web + worker (keyless demo works immediately)"
  say "  http://localhost:3000  → the signal board"
  say "  /silas/inbox           → where the held digest waits for you"
  say "  bin/ci                 → tests + agent evals, no key needed"
  say ""
  say "Real model: export ANTHROPIC_API_KEY=sk-ant-... and restart bin/dev."
  say "──────────────────────────────────────────────────────────", :green
end
