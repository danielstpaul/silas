module Silas
  module Api
    module V1
      class TurnsController < Silas::Api::BaseController
        include Silas::Api::Serialization

        # POST /silas/api/v1/sessions/:session_id/turns  { input: }
        # 409 when a turn is already active — an API must surface it, not
        # swallow it the way the webhook channels do.
        def create
          session = Silas::Session.find(params[:session_id])
          input = params[:input].to_s.strip
          return render json: { error: "input is required" }, status: :unprocessable_entity if input.empty?

          turn = session.continue(input: input)
          render json: turn_json(turn), status: :created
        rescue Silas::TurnInProgressError => e
          render json: { error: e.message }, status: :conflict
        end

        # POST /silas/api/v1/turns/:id/cancel
        # Running turns are flagged (honored at the next step boundary);
        # queued/parked turns cancel immediately — cancel: reflects which.
        def cancel
          turn = Silas::Turn.find(params[:id])
          outcome = turn.cancel!(reason: "canceled via api by #{current_actor}")
          render json: turn_json(turn.reload).merge(cancel: outcome)
        end
      end
    end
  end
end
