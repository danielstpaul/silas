# coding: utf-8

# Silas application template — a deployable agent app from nothing:
#
#   rails new desk -m https://raw.githubusercontent.com/danielstpaul/silas/main/template.rb
#
# What you get: a refund desk agent (three tools, one per effect mode, with a
# money gate that holds refunds over £25 for a human), the operator inbox
# mounted at /silas/inbox, Solid Queue wired in development (the durability
# contract needs a real worker), a keyless scripted demo so the first boot
# works with zero secrets, deterministic agent evals as a CI gate, and a
# signal-board landing page.
#
# The template only runs generators and writes files you own — delete the desk
# and write your own agent whenever you're ready. Requires Rails >= 8.1.
#
# CI note: SILAS_PATH=/path/to/checkout uses a local silas instead of the
# released gem (this is how silas's own template_smoke workflow verifies that
# this file can never drift from the gem).

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
  # Initializers, app/agent skeleton, channels, the Claude Code skill,
  # recurring.yml rescuer entry, engine mount, and the silas migrations.
  generate "silas:install"

  # ── The desk: one agent, three tools, one per effect mode ────────────────
  remove_file "app/agent/tools/example_tool.rb"

  create_file "app/agent/instructions.md", force: true, verbose: true do
    <<~'MD'
      # The refund desk

      You are the refund desk for a small goods shop, talking directly to
      customers about their orders.

      Rules:

      - Always look the order up before promising anything.
      - Never quote an amount a tool didn't return.
      - Refunds at or under £25.00 clear immediately. Larger refunds are issued
        the same way but HOLD for a person on our side to clear — tell the
        customer it's been sent for a quick check, never that it failed.
      - After any refund goes through, send the customer a short confirmation.

      Tone: plain, warm, brief. Pounds and pence — never abstract units.
    MD
  end

  create_file "app/agent/agent.yml", force: true do
    <<~'YAML'
      # Data-only agent config. Model defaults to Silas.config.default_model.
      # model: claude-sonnet-4-5
      description: Refund desk — looks up orders, issues refunds (holds over £25), sends confirmations.
      limits:
        max_steps: 8      # model calls per turn
        max_cost: 0.25    # dollars per turn
        timeout: 300      # seconds of ACTIVE work — held time doesn't count
    YAML
  end

  create_file "app/agent/tools/lookup_order.rb" do
    <<~'RUBY'
      # Tool identity is the filename: this is the "lookup_order" tool.
      # The keyword signature of #call IS the schema the model sees.
      class Agent::Tools::LookupOrder < Silas::Tool
        description "Look up an order by its number (e.g. R-1002)."
        idempotent! # read-only, so crash replays may re-run it freely

        def call(number:)
          order = Order.find_by(number: number.to_s.upcase.strip)
          return { error: "no order #{number}" } unless order

          { number: order.number, email: order.email, item: order.item,
            amount_pence: order.amount_pence, status: order.status,
            refunded_pence: order.refunds.sum(:amount_pence) }
        end
      end
    RUBY
  end

  create_file "app/agent/tools/issue_refund.rb" do
    <<~'RUBY'
      # The money path. transactional! means the refund row and the ledger's
      # "this ran" record commit in ONE database transaction — exactly-once,
      # even through kill -9 mid-turn. Only ever declare it when the side
      # effect lives in this app's own tables; the ledger cannot roll back a
      # sent email.
      class Agent::Tools::IssueRefund < Silas::Tool
        description "Refund part or all of an order."
        param :amount_pence, :integer, desc: "Amount to refund, in pence (1800 = £18.00)"
        transactional!
        # At or under £25 the agent clears itself; over £25 the turn HOLDS at
        # the signal — zero compute — until a person clears it in /silas/inbox.
        approval ->(session:, input:) { input[:amount_pence] > 2_500 ? :user_approval : :approved }

        def call(number:, amount_pence:, reason:)
          order = Order.find_by(number: number.to_s.upcase.strip)
          return { error: "no order #{number}" } unless order

          remaining = order.amount_pence - order.refunds.sum(:amount_pence)
          return { error: "only #{remaining}p left to refund on #{order.number}" } if amount_pence > remaining

          refund = order.refunds.create!(amount_pence: amount_pence, reason: reason)
          order.update!(status: "refunded") if amount_pence == remaining
          { refunded_pence: refund.amount_pence, order: order.number, refund_id: refund.id }
        end
      end
    RUBY
  end

  create_file "app/agent/tools/notify_customer.rb" do
    <<~'RUBY'
      # External side effects (email, Slack, SMS, any HTTP call) stay
      # at_most_once! — if a crash makes "did it actually send?" ambiguous,
      # the invocation parks IN DOUBT for a human verdict instead of firing
      # again blind. Swap the body for your real transport; keep the mode.
      class Agent::Tools::NotifyCustomer < Silas::Tool
        description "Send the customer a short confirmation note about their order."
        at_most_once!

        def call(number:, message:)
          order = Order.find_by(number: number.to_s.upcase.strip)
          return { error: "no order #{number}" } unless order

          # Stand-in transport: replace with your mailer / Slack / SMS call.
          Rails.logger.info("[desk] to=#{order.email}: #{message}")
          { delivered: true, to: order.email }
        end
      end
    RUBY
  end

  # ── Domain: orders + refunds ─────────────────────────────────────────────
  # Fixed past timestamp: a generation-time stamp can land in the same second
  # as the silas migrations the installer copies, colliding on version number.
  create_file "db/migrate/20260101000000_create_desk.rb" do
    <<~'RUBY'
      class CreateDesk < ActiveRecord::Migration[8.1]
        def change
          create_table :orders do |t|
            t.string :number, null: false
            t.string :email, null: false
            t.string :item, null: false
            t.integer :amount_pence, null: false
            t.string :status, null: false, default: "paid"
            t.timestamps
          end
          add_index :orders, :number, unique: true

          create_table :refunds do |t|
            t.references :order, null: false, foreign_key: true
            t.integer :amount_pence, null: false
            t.string :reason
            t.timestamps
          end
        end
      end
    RUBY
  end

  create_file "app/models/order.rb" do
    <<~'RUBY'
      class Order < ApplicationRecord
        has_many :refunds, dependent: :destroy
      end
    RUBY
  end

  create_file "app/models/refund.rb" do
    <<~'RUBY'
      class Refund < ApplicationRecord
        belongs_to :order
      end
    RUBY
  end

  append_to_file "db/seeds.rb" do
    <<~'RUBY'
      [
        { number: "R-1001", email: "ada@example.com",   item: "field notebook",       amount_pence: 1_800 },
        { number: "R-1002", email: "ada@example.com",   item: "walnut monitor stand", amount_pence: 6_400 },
        { number: "R-1003", email: "grace@example.com", item: "canvas tote",          amount_pence: 2_200 }
      ].each do |attrs|
        Order.find_or_create_by!(number: attrs[:number]) { |o| o.assign_attributes(attrs) }
      end
    RUBY
  end

  # ── Keyless demo: a scripted stand-in when no provider key is set ────────
  # It fakes ONLY the model's decisions. Everything else is real: the tools
  # hit the real tables, the Ledger enforces exactly-once, the £64 refund
  # genuinely holds for approval. (Same seam the eval harness scripts.)
  create_file "lib/demo_adapter.rb" do
    <<~'RUBY'
      class DemoAdapter < Silas::Adapters::Base
        def execute_step(context, &on_event)
          input = context[:turn].input.to_s.downcase
          index = context[:index]

          if input.include?("r-1002")
            held_story(index, &on_event)
          elsif input.include?("r-1001")
            clear_story(index, &on_event)
          else
            say("(Keyless demo — I'm a scripted stand-in, not a model. I know two " \
                "stories: order R-1001, an £18 field notebook that arrived damaged " \
                "— that refund clears itself — and order R-1002, a £64 walnut " \
                "monitor stand that arrived cracked — that refund HOLDS at the " \
                "signal until you clear it in /silas/inbox. Mention an order " \
                "number to start one. Set ANTHROPIC_API_KEY and restart to talk " \
                "to a real model.)", &on_event)
          end
        end

        private

        # £18 — under the gate: looks up, refunds immediately, confirms.
        def clear_story(index, &on_event)
          case index
          when 0 then tool("lookup_order", { "number" => "R-1001" })
          when 1 then tool("issue_refund", { "number" => "R-1001", "amount_pence" => 1800,
                                             "reason" => "arrived damaged" })
          when 2 then tool("notify_customer", { "number" => "R-1001",
                                                "message" => "We've refunded £18.00 for the field notebook." })
          else say("Sorry about the notebook, Ada — I've refunded the full £18.00 to your " \
                   "original payment method and sent a confirmation. It should appear " \
                   "within a few days.", &on_event)
          end
        end

        # £64 — over the gate: the refund call HOLDS for a human. Clearing it
        # in /silas/inbox resumes the turn exactly where it stopped.
        def held_story(index, &on_event)
          case index
          when 0 then tool("lookup_order", { "number" => "R-1002" })
          when 1 then tool("issue_refund", { "number" => "R-1002", "amount_pence" => 6400,
                                             "reason" => "arrived cracked" })
          when 2 then tool("notify_customer", { "number" => "R-1002",
                                                "message" => "We've refunded £64.00 for the walnut monitor stand." })
          else say("That's no good at all — a cracked stand isn't what you paid for. " \
                   "The full £64.00 refund has just been cleared on our side and is on " \
                   "its way back to you, with a confirmation in your inbox.", &on_event)
          end
        end

        def tool(name, arguments)
          # A real model call takes a second or two; the pause keeps the live
          # trace readable (rows are durable either way — refresh shows all).
          sleep 0.7
          Silas::Adapters::Result.new(
            blocks: [],
            tool_calls: [ Silas::Adapters::ToolCall.new(id: "demo_#{name}", name: name, arguments: arguments) ],
            stop_reason: "tool_use",
            usage: { input_tokens: 40, output_tokens: 15 }
          )
        end

        def say(text, &on_event)
          text.chars.each_slice(3) do |chunk|
            on_event&.call(Silas::Event.new(type: :text_delta, payload: { text: chunk.join }))
            sleep 0.025
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
  # stand-in drives the desk (lib/demo_adapter.rb) - the tools, ledger, and
  # approval hold are all real. Set ANTHROPIC_API_KEY to use a real model.
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
  # Rails defaults dev to the in-process :async job adapter, which runs a
  # re-enqueued continuation CONCURRENTLY with the original — that breaks
  # exactly-once. And live token deltas cross from the worker process to the
  # browser, which the in-process async cable adapter can't carry.
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
  create_file "test/agent_evals/refund_desk_eval.rb" do
    <<~'RUBY'
      # Deterministic evals: the MODEL's decisions are scripted, but the real
      # Ledger runs the real tools against the real tables — so these assert
      # on a genuine transcript, not a mock. Run: bin/rails silas:eval
      # (bin/ci gates on them; they need the seeds: bin/rails db:seed).

      Silas::Eval.scenario "under the gate: an £18 refund clears itself" do
        input "My field notebook (order R-1001) arrived damaged."

        on_step 0, call: { name: "lookup_order", arguments: { number: "R-1001" } }
        on_step 1, call: { name: "issue_refund",
                           arguments: { number: "R-1001", amount_pence: 1800, reason: "arrived damaged" } }
        on_step 2, call: { name: "notify_customer",
                           arguments: { number: "R-1001", message: "We've refunded £18.00 for the field notebook." } }
        on_step 3, text: "Sorry about the notebook — I've refunded the full £18.00 and sent a confirmation."

        expect do
          assert_turn_completed
          assert_tool_called "issue_refund", times: 1
          assert_approved tool: "issue_refund"   # under £25: auto-approved, never held
          assert_final_matches(/£18\.00/)
          assert_no_hallucinated_price
        end
      end

      Silas::Eval.scenario "over the gate: a £64 refund holds at the signal" do
        input "The walnut monitor stand (order R-1002) arrived cracked."

        on_step 0, call: { name: "lookup_order", arguments: { number: "R-1002" } }
        on_step 1, call: { name: "issue_refund",
                           arguments: { number: "R-1002", amount_pence: 6400, reason: "arrived cracked" } }

        expect do
          # £64 is over the gate: the turn holds at zero compute and the
          # refund row does NOT exist yet. The money-moving guarantee, asserted.
          assert_parked tool: "issue_refund"
          assert_no_tool_called "issue_refund"
        end
      end

      Silas::Eval.scenario "clearing the held refund executes it exactly once" do
        input "The walnut monitor stand (order R-1002) arrived cracked."

        on_step 0, call: { name: "issue_refund",
                           arguments: { number: "R-1002", amount_pence: 6400, reason: "arrived cracked" } }
        on_step 1, call: { name: "notify_customer",
                           arguments: { number: "R-1002", message: "We've refunded £64.00 for the walnut monitor stand." } }
        on_step 2, text: "Cleared and refunded £64.00 for the walnut monitor stand."

        approve tool: "issue_refund"   # the same approve! the inbox, Slack, and email use

        expect do
          assert_turn_completed
          assert_approved tool: "issue_refund"
          assert_tool_called "issue_refund", times: 1   # exactly once, across the hold
          assert_tool_arg "issue_refund", :amount_pence, 6400
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

  # ── The landing page: a signal board for your agent ──────────────────────
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
          lamp as the accent (never a status), aspect colours for state. The
          tokens below are the full Silas set; build your own pages on them. %>
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
        header.board .mark { display: block; }
        header.board .mark .bezel { stroke: var(--ink); }
        header.board .mark .lamp { fill: var(--accent); }
        header.board nav { margin-left: auto; }
        a { color: var(--accent); text-underline-offset: 2px; }
        h1 { font-family: var(--sans-display); font-weight: 800; letter-spacing: -0.02em;
             font-size: 34px; margin: 18px 0 8px; }
        .sub { color: var(--muted); margin: 0 0 26px; max-width: 56ch; line-height: 1.5; }
        .board-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 10px; }
        @media (max-width: 560px) { .board-grid { grid-template-columns: repeat(2, 1fr); } }
        .aspect { border-radius: var(--radius); padding: 14px 14px 12px; border: 1px solid transparent; }
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

        <h1>The desk is open.</h1>
        <p class="sub">
          A refund desk agent runs inside this app. Reads move freely; anything
          that moves money over £25 holds at the signal until you clear it —
          and every tool effect lands exactly once, even through a crash.
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
            <strong>keyless demo</strong> — a scripted stand-in is driving the desk.
            The tools, the ledger, and the hold are all real; only the model's
            decisions are canned. Set <code>ANTHROPIC_API_KEY</code> and restart
            to talk to a real model.
          </div>
        <% end %>

        <div class="card">
          <h2>This agent</h2>
          <div class="row"><span class="k">model</span>
            <span><%= @demo ? "scripted stand-in (no key set)" : @model %></span></div>
          <div class="row"><span class="k">tools</span>
            <span><% @tools.each do |t| %><code class="chip"><%= t %></code><% end %></span></div>
          <div class="row"><span class="k">the gate</span>
            <span>refunds over £25.00 hold for a person — approve or decline them in the inbox</span></div>
          <div class="row"><span class="k">defined in</span>
            <span><code class="chip">app/agent/</code> — instructions, tools, skills, schedules. The directory is the agent.</span></div>
        </div>

        <div class="card">
          <h2>Try it — start a session in the inbox</h2>
          <ul class="try">
            <li>
              <code>My field notebook (order R-1001) arrived damaged.</code>
              <span class="fate">£18 — under the gate: refunds itself, exactly once, and confirms.</span>
            </li>
            <li>
              <code>The walnut monitor stand (order R-1002) arrived cracked.</code>
              <span class="fate">£64 — over the gate: holds at the signal until you clear it. Watch the amber card.</span>
            </li>
            <li>
              <code>bin/rails silas:chat</code>
              <span class="fate">the same desk, from your terminal.</span>
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
      # The desk

      An agent app built on [Silas](https://github.com/danielstpaul/silas) —
      durable AI agents for Rails. A refund desk runs inside it: reads move
      freely, refunds over £25 **hold at the signal** until a person clears
      them, and every tool effect lands **exactly once**, even through a crash.

      ## First run — no API key needed

      ```sh
      bin/setup
      bin/dev        # web + the Solid Queue worker (the durability contract needs both)
      ```

      Open <http://localhost:3000> — the signal board — then start a session in
      the inbox and paste one of the two stories:

      | prompt | what happens |
      |---|---|
      | `My field notebook (order R-1001) arrived damaged.` | £18 — under the gate. The agent looks it up, refunds it, confirms. |
      | `The walnut monitor stand (order R-1002) arrived cracked.` | £64 — over the gate. The refund **holds**; clear it from the amber card and the turn resumes exactly where it stopped. |

      With no `ANTHROPIC_API_KEY` set, a scripted stand-in plays the model —
      the tools, ledger, and hold are all real. Export a key and restart to
      talk to a real model.

      ## The agent is a directory

      ```
      app/agent/
        instructions.md        # persona
        agent.yml              # model + per-turn limits (steps, cost, timeout)
        tools/
          lookup_order.rb      # idempotent!     — read-only, replays freely
          issue_refund.rb      # transactional!  — DB effect: exactly-once, gated over £25
          notify_customer.rb   # at_most_once!   — external effect: parks IN DOUBT on a crash
        skills/ schedules/ channels/
      ```

      The three tools are one-per-effect-mode on purpose — copy the one whose
      shape matches your side effect. `.claude/skills/silas/SKILL.md` teaches
      coding agents these rules, so you can build the next tool by asking for it.

      ## Tests and evals — keyless, deterministic

      ```sh
      bin/ci               # app tests + agent evals
      bin/rails silas:eval # just the evals
      ```

      Evals script the **model's decisions** and assert on the **real ledger**:
      the £64 scenario asserts the turn held and no refund row existed, then a
      second scenario clears it and asserts exactly-once execution. See
      `test/agent_evals/refund_desk_eval.rb`.

      ## Going live

      1. `ANTHROPIC_API_KEY` (or any provider RubyLLM supports) in production env.
      2. Replace the dev-only inbox auth in `config/initializers/silas.rb`.
      3. `bin/rails silas:doctor` — verifies key, queue adapter, migrations, rescuer.
      4. Deploy with Kamal as usual; the deep guide ships in the gem:
         `bundle show silas` → `DEPLOY.md` (worker liveness, the rescuer, scaling).

      Replace the desk with your own agent whenever you're ready — delete the
      orders/refunds models and the three tools, write yours, restart.
    MD
  end

  # ── Databases ready + seeded ─────────────────────────────────────────────
  rails_command "db:prepare"
  rails_command "db:seed"

  say ""
  say "──────────────────────────────────────────────────────────", :green
  say "The desk is open.", :green
  say ""
  say "  cd #{app_name}"
  say "  bin/dev                → web + worker (keyless demo works immediately)"
  say "  http://localhost:3000  → the signal board"
  say "  /silas/inbox           → where held refunds wait for you"
  say "  bin/ci                 → tests + agent evals, no key needed"
  say ""
  say "Real model: export ANTHROPIC_API_KEY=sk-ant-... and restart bin/dev."
  say "──────────────────────────────────────────────────────────", :green
end
