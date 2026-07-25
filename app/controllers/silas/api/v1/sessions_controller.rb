module Silas
  module Api
    module V1
      class SessionsController < Silas::Api::BaseController
        include Silas::Api::Serialization

        # POST /silas/api/v1/sessions  { input:, agent: (optional), metadata: (optional) }
        # channel stays nil ("direct") — API consumers read state via GET/stream;
        # a non-nil channel would enqueue pointless outbound delivery jobs.
        def create
          input = params[:input].to_s.strip
          return render json: { error: "input is required" }, status: :unprocessable_entity if input.empty?

          handle = params[:agent].present? ? Silas.agent(params[:agent]) : Silas.agent
          session = handle.start(input: input, metadata: metadata_param)
          render json: session_json(session.reload), status: :created
        rescue Silas::TurnInProgressError => e
          render json: { error: e.message }, status: :conflict
        rescue Silas::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # GET /silas/api/v1/sessions/:id         — session + turns
        # GET /silas/api/v1/sessions/:id?trace=1 — plus steps + invocations
        def show
          session = Silas::Session.includes(turns: { steps: :tool_invocations }).find(params[:id])
          render json: session_json(session, trace: params[:trace].present?)
        end

        private

        def metadata_param
          raw = params[:metadata]
          raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : (raw.presence || {})
        end
      end
    end
  end
end
