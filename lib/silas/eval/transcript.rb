module Silas
  module Eval
    # Read-only view over a turn at its resting state — the surface assertions read.
    class Transcript
      attr_reader :turn, :session

      def initialize(turn, session)
        @turn = turn
        @session = session
      end

      def input      = @turn.input
      def status     = @turn.status
      def completed? = @turn.completed?
      def parked?    = @turn.parked?
      def final_text = @turn.answer_text.to_s
      def invocations = @turn.tool_invocations.order(:id).to_a
      def invocations_for(name) = invocations.select { |i| i.tool_name == name.to_s }
      def results = invocations.map(&:result).compact
    end
  end
end
