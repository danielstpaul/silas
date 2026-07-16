require "json"
require "fileutils"

module Chaos
  # The Phase 0 spike harness, repointed at the gem. Kills Silas::AgentLoopJob
  # at random points and measures completion, transcript integrity, and
  # duplicated tool side effects. The gem's ledger IS cell C — the gate is:
  # 100% completion, 0 duplicates, byte-identical canonical transcripts.
  #
  # Modes: worker (kill -9 the worker fork; supervisor reaps → ProcessExitError)
  #        supervisor (kill -9 the whole tree; fresh boot prunes → ProcessPrunedError)
  #        sigterm (graceful, Kamal deploy shape)
  #        parked (approval park + hard kill + 24h rewind + approve!)
  class Runner
    RESULTS_DIR = File.expand_path("../../results", __dir__)
    COMPLETION_TIMEOUT = 240 # generous: chaos runs share a desktop with real work

    attr_reader :runs, :mode, :scenario, :store

    def initialize(runs:, mode:, scenario: "default")
      @runs = runs
      @mode = mode
      @scenario = mode == "parked" ? "approval" : scenario
      @store = ENV["STORE"] == "pg" ? "pg" : "sqlite"
      @worker_pgid = nil
    end

    def call
      FileUtils.mkdir_p(RESULTS_DIR)
      return parked_batch if mode == "parked"

      control = control_run
      puts "control: #{control[:duration_ms]}ms, #{control[:side_effects]} side effects, transcript #{control[:transcript].bytesize} bytes"

      results = (1..runs).map do |i|
        r = chaos_run(i, control)
        puts format("run %03d/%d: completed=%s identical=%s dups=%d rescues=%d total=%dms",
                    i, runs, r[:completed], r[:transcript_identical], r[:duplicate_side_effects],
                    r[:rescuer_retries], r[:total_ms])
        r
      end
      persist(results, mode)
      summarize(results)
    ensure
      stop_worker
    end

    private

    def control_run
      reset!
      start_worker
      session, turn = enqueue
      t0 = monotonic_ms
      raise "control run did not complete" unless wait_for_completion(turn)

      { duration_ms: (monotonic_ms - t0).round,
        transcript: canonical_transcript(session),
        side_effects: SideEffectRow.where(session_id: session.id).count }
    ensure
      stop_worker
    end

    def chaos_run(index, control)
      reset!
      start_worker
      session, turn = enqueue
      t0 = monotonic_ms

      kill_at = rand(0.05..0.95) * control[:duration_ms]
      sleep(kill_at / 1000.0)
      kill!

      rescues = recover(turn)
      completed = wait_for_completion(turn)

      {
        run: index, store: store, mode: mode, scenario: scenario,
        completed: completed,
        transcript_identical: completed && canonical_transcript(session) == control[:transcript],
        duplicate_side_effects: duplicate_count(session),
        kill_at_ms: kill_at.round,
        total_ms: (monotonic_ms - t0).round,
        rescuer_retries: rescues
      }
    ensure
      stop_worker
    end

    def parked_batch
      control = parked_control
      results = (1..runs).map do |i|
        r = parked_run(i, control)
        puts format("parked %d/%d: parked=%s completed=%s identical=%s dups=%d",
                    i, runs, r[:parked_ok], r[:completed], r[:transcript_identical], r[:duplicate_side_effects])
        r
      end
      persist(results, "parked")
      summarize(results)
    ensure
      stop_worker
    end

    def parked_control
      reset!
      start_worker
      session, turn = enqueue
      wait_until(30) { turn.reload.status == "waiting" } or raise "control did not park"
      session.pending_approvals.sole.approve!(by: "chaos")
      raise "parked control did not complete" unless wait_for_completion(turn)

      { transcript: canonical_transcript(session) }
    ensure
      stop_worker
    end

    def parked_run(index, control)
      reset!
      start_worker
      session, turn = enqueue

      parked_ok = wait_until(30) { turn.reload.status == "waiting" } &&
                  wait_until(10) { SolidQueue::ClaimedExecution.count.zero? }

      hard_kill_all!
      rewind_timestamps!(24 * 3600)

      start_worker
      session.pending_approvals.sole.approve!(by: "chaos")
      rescues = recover(turn)
      completed = wait_for_completion(turn)

      {
        run: index, store: store, mode: "parked", scenario: scenario,
        parked_ok: parked_ok, completed: completed,
        transcript_identical: completed && canonical_transcript(session) == control[:transcript],
        duplicate_side_effects: duplicate_count(session),
        rescuer_retries: rescues
      }
    ensure
      stop_worker
    end

    # -- processes (pgroup-scoped: another app's Solid Queue runs on this box) --

    def start_worker
      log = File.expand_path("../../log/jobs.log", __dir__)
      @worker_pgid = Process.spawn(
        { "STORE" => ENV["STORE"].to_s,
          "MODEL_TURN_MS" => ENV.fetch("MODEL_TURN_MS", "120"),
          "CHAOS_STEPS" => ENV.fetch("CHAOS_STEPS", "8"),
          "PGGSSENCMODE" => "disable", "OBJC_DISABLE_INITIALIZE_FORK_SAFETY" => "YES" },
        "bin/jobs", pgroup: true, chdir: File.expand_path("../..", __dir__), out: log, err: log
      )
      wait_until(60) { my_processes(kind: "Worker").any? } or raise "worker never registered"
    end

    def stop_worker
      return unless @worker_pgid

      begin
        Process.kill("-TERM", @worker_pgid)
        Process.wait(@worker_pgid)
      rescue Errno::ESRCH, Errno::ECHILD
      end
      @worker_pgid = nil
    end

    def my_processes(kind:)
      SolidQueue::Process.where(kind: kind).select { |p| in_our_pgroup?(p.pid) }
    end

    def in_our_pgroup?(pid)
      Process.getpgid(pid) == @worker_pgid
    rescue Errno::ESRCH
      false
    end

    def kill!
      case mode
      when "worker"
        worker = my_processes(kind: "Worker").first
        Process.kill("KILL", worker.pid) if worker
      when "supervisor" then hard_kill_all!
      when "sigterm"
        pgid = @worker_pgid
        Process.kill("-TERM", pgid)
        begin
          Process.wait(pgid)
        rescue Errno::ECHILD
        end
        @worker_pgid = nil
      else raise ArgumentError, "unknown mode #{mode}"
      end
    end

    def hard_kill_all!
      Process.kill("-KILL", @worker_pgid)
      begin
        Process.wait(@worker_pgid)
      rescue Errno::ECHILD
      end
      @worker_pgid = nil
    end

    # -- recovery ---------------------------------------------------------------

    def recover(turn)
      start_worker if @worker_pgid.nil?
      rescues = 0
      deadline = monotonic_ms + COMPLETION_TIMEOUT * 1000
      until terminal?(turn) || monotonic_ms > deadline
        rescues += Silas::DeadJobRescuerJob.new.perform
        break if terminal?(turn)

        sleep 0.3
      end
      rescues
    end

    def terminal?(turn)
      %w[completed failed canceled].include?(turn.reload.status)
    end

    # -- metrics ----------------------------------------------------------------

    def duplicate_count(session)
      SideEffectRow.where(session_id: session.id).group(:key).count.values.sum { |c| c - 1 }
    end

    # Id/timestamp-free canonical serialization — the rows ARE the transcript.
    def canonical_transcript(session)
      session.turns.reload.order(:index).map { |turn|
        steps = Silas::Step.where(turn_id: turn.id).order(:index).map { |s|
          invs = Silas::ToolInvocation.where(step_id: s.id).order(:tool_call_id).map { |i|
            "#{i.tool_call_id}\t#{i.tool_name}\t#{i.status}\t#{JSON.generate(i.result || {})}"
          }.join("\n")
          "#{s.index}\t#{s.terminal.inspect}\t#{JSON.generate(s.response_blocks || [])}\n#{invs}"
        }.join("\n")
        "TURN #{turn.index}\t#{turn.status}\t#{turn.input}\n#{steps}"
      }.join("\n")
    end

    def wait_for_completion(turn)
      wait_until(COMPLETION_TIMEOUT) { turn.reload.status == "completed" }
    end

    # -- infrastructure ---------------------------------------------------------

    def enqueue
      session = Silas.agent.start(input: "chaos run", metadata: { "scenario" => scenario })
      [ session, session.turns.sole ]
    end

    def reset!
      [ Silas::ToolInvocation, Silas::Step, Silas::Turn, Silas::Session, SideEffectRow ].each(&:delete_all)
      [ SolidQueue::Job, SolidQueue::ReadyExecution, SolidQueue::ClaimedExecution,
        SolidQueue::ScheduledExecution, SolidQueue::FailedExecution,
        SolidQueue::BlockedExecution, SolidQueue::Process ].each(&:delete_all)
    end

    def rewind_timestamps!(seconds)
      tables = {
        Silas::Session => %w[created_at updated_at],
        Silas::Turn => %w[created_at updated_at started_at],
        Silas::Step => %w[created_at updated_at],
        Silas::ToolInvocation => %w[created_at updated_at approval_expires_at],
        SideEffectRow => %w[created_at updated_at],
        SolidQueue::Job => %w[created_at updated_at finished_at]
      }
      tables.each do |model, columns|
        sets = columns.map { |col|
          if store == "sqlite"
            "#{col} = datetime(#{col}, '-#{seconds} seconds')"
          else
            "#{col} = #{col} - interval '#{seconds} seconds'"
          end
        }.join(", ")
        model.update_all(sets)
      end
    end

    def wait_until(timeout_s)
      deadline = monotonic_ms + timeout_s * 1000
      until yield
        return false if monotonic_ms > deadline

        sleep 0.1
      end
      true
    end

    def monotonic_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000

    def persist(results, mode_name)
      path = File.join(RESULTS_DIR, "#{store}_#{mode_name}.jsonl")
      File.open(path, "a") { |f| results.each { |r| f.puts(r.to_json) } }
      @path = path
    end

    def summarize(results)
      total = results.size
      puts
      puts "=== silas/#{store}/#{mode}: #{results.count { |r| r[:completed] }}/#{total} completed, " \
           "#{results.count { |r| r[:transcript_identical] }}/#{total} transcripts identical, " \
           "#{results.sum { |r| r[:duplicate_side_effects] }} duplicate side effects " \
           "(max #{results.map { |r| r[:duplicate_side_effects] }.max}/run) -> #{@path}"
    end
  end
end
