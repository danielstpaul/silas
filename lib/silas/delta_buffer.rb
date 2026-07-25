module Silas
  # Coalesces model text deltas into ~10Hz "delta.silas" notifications carrying
  # the ACCUMULATED text so far — subscribers replace rather than append, which
  # is idempotent under a crash-restream (same step id, fresh stream overwrites
  # itself) and ordering-safe under Turbo. Deltas are decoration over the
  # authoritative row render: never persisted, never fed back to the model, and
  # a replayed step (already completed) emits none.
  #
  # Payload: { session_id:, turn_id:, step_id:, step_index:, text: } — every
  # subscriber MUST filter by these ids (notifications are process-global; a
  # busy worker interleaves deltas from concurrent turns).
  class DeltaBuffer
    INTERVAL = 0.1 # seconds between publishes; #finish flushes the tail

    def initialize(turn:, step:)
      @turn = turn
      @step = step
      @text = +""
      @published = 0
      @last_publish = 0.0
    end

    def append(text)
      return if text.empty?

      @text << text
      publish if clock - @last_publish >= INTERVAL
    end

    # The final flush. StepRunner calls this BEFORE the step row commits, so
    # the authoritative after_commit render can never race a straggling batch.
    def finish = publish

    private

    def publish
      return if @text.empty? || @text.length == @published

      @published = @text.length
      @last_publish = clock
      Silas.instrument(
        :delta,
        session_id: @turn.session_id, turn_id: @turn.id,
        step_id: @step.id, step_index: @step.index, text: @text.dup
      )
    end

    def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
