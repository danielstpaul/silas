require "json"

module Silas
  module Api
    module V1
      # Server-sent events at ROW granularity: turn / completed-step /
      # invocation changes polled from the durable rows — the same source of
      # truth as everything else. Deliberately NOT per-token: deltas are
      # emitted in the worker process and the gem requires no cross-process
      # bus; per-token streaming is the Turbo/browser feature.
      #
      # Delivery is at-least-once with Last-Event-ID resume: event ids are
      # epoch-millisecond watermarks, each poll re-reads a 1ms overlap, and
      # clients dedup by (event type, id, status). `?poll=1` emits the backlog
      # since Last-Event-ID and closes — curl-able, and how the request specs
      # exercise the cursor without holding a live stream.
      #
      # Live actions run on their own thread and hold a Puma thread for the
      # stream's lifetime — inherent to SSE. The AR connection is NOT held:
      # each poll checks one out and returns it before sleeping, and the
      # stream closes itself after api_stream_max_duration (clients reconnect
      # with Last-Event-ID).
      class StreamsController < Silas::Api::BaseController
        include ActionController::Live
        include Silas::Api::Serialization

        HEARTBEAT_EVERY = 15 # seconds; comment-frames keep proxies alive

        def show
          session_id = with_connection { Silas::Session.find(params[:id]).id }

          response.headers["Content-Type"] = "text/event-stream"
          response.headers["Cache-Control"] = "no-cache"
          response.headers["X-Accel-Buffering"] = "no" # nginx: never buffer SSE
          # Whatever the router/auth checked out must not stay pinned for the
          # stream's lifetime.
          ActiveRecord::Base.connection_handler.clear_active_connections!

          watermark = initial_watermark
          deadline = clock + Silas.config.api_stream_max_duration
          last_beat = clock

          loop do
            events = with_connection { collect_changes(session_id, watermark) }
            events.each do |type, at, payload|
              write_event(type, payload, watermark_ms(at))
              watermark = at if at > watermark
            end

            break if params[:poll].present? # backlog served; close

            if clock >= deadline
              write_event("timeout", { reconnect: true }, watermark_ms(watermark))
              break
            end

            if clock - last_beat >= HEARTBEAT_EVERY
              response.stream.write(": hb\n\n")
              last_beat = clock
            end

            sleep Silas.config.api_stream_poll_interval
          end
        rescue IOError, ActionController::Live::ClientDisconnected
          # client went away — the normal end of an SSE stream
        ensure
          response.stream.close rescue nil
        end

        private

        # Everything with updated_at at-or-after the watermark (1ms overlap —
        # at-least-once beats a gap). Steps only when completed: their text is
        # the payload, and incomplete steps have none.
        def collect_changes(session_id, watermark)
          overlap = watermark - 0.001
          events = []

          Silas::Turn.where(session_id: session_id).where(updated_at: overlap..)
                     .order(:updated_at, :id).each do |turn|
            events << [ "turn", turn.updated_at, turn_json(turn) ]
          end
          Silas::Step.joins(:turn).where(silas_turns: { session_id: session_id })
                     .where(status: "completed").where(updated_at: overlap..)
                     .order(:updated_at, :id).each do |step|
            events << [ "step", step.updated_at, step_json(step) ]
          end
          Silas::ToolInvocation.joins(:turn).where(silas_turns: { session_id: session_id })
                               .where(updated_at: overlap..)
                               .order(:updated_at, :id).each do |invocation|
            events << [ "invocation", invocation.updated_at, invocation_json(invocation) ]
          end

          events.sort_by { |(_type, at, _payload)| at }
        end

        def write_event(type, payload, id_ms)
          response.stream.write("id: #{id_ms}\nevent: #{type}\ndata: #{JSON.generate(payload)}\n\n")
        end

        # Last-Event-ID (header or param) in epoch ms; absent -> "from now"
        # (GET /sessions/:id carries current state; the stream carries what
        # changes next). Last-Event-ID: 0 replays the whole session.
        def initial_watermark
          raw = request.headers["Last-Event-ID"].presence || params[:last_event_id].presence
          raw ? Time.zone.at(raw.to_i / 1000.0) : Time.zone.now
        end

        def watermark_ms(time) = (time.to_f * 1000).round

        def with_connection(&) = ActiveRecord::Base.connection_pool.with_connection(&)

        def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
