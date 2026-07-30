module Silas
  module Channels
    # Slack transport webhooks. Inbound messages start/continue a session;
    # interactive button clicks map to the existing invocation.approve!/decline!.
    # Requires app/agent/channels/slack.rb (Agent::Channels::Slack) to exist.
    class SlackController < BaseController
      # POST /channels/slack/events
      def events
        return unless verify_slack!
        return render(json: { challenge: params[:challenge] }) if params[:type] == "url_verification"
        # Slack retries deliver at-least-once; ignore retries (continuation-token
        # uniqueness + single-active-turn are the real dedup).
        return head(:ok) if request.headers["X-Slack-Retry-Num"].present?

        event = params[:event]
        if event && event[:type] == "message" && event[:bot_id].blank? && event[:subtype].blank?
          thread_key = "#{params[:team_id]}:#{event[:channel]}:#{event[:thread_ts] || event[:ts]}"
          channel_class.dispatch(
            thread_key: thread_key, input: event[:text].to_s,
            # Which staff member owns this Slack channel (nil -> the root agent).
            agent: Silas::Channel.route_for("slack", event[:channel]),
            metadata: { "slack" => { "channel" => event[:channel],
                                     "thread_ts" => event[:thread_ts] || event[:ts],
                                     "user" => event[:user] } }
          )
        end
        head :ok
      rescue Silas::TurnInProgressError
        head :ok # single-active-turn: a reply mid-turn is dropped (v1 policy)
      end

      # POST /channels/slack/actions
      def actions
        return unless verify_slack!

        payload = JSON.parse(params[:payload])
        action = payload.fetch("actions").first
        invocation = Silas::ToolInvocation.find(action["value"])
        who = "slack:#{payload.dig('user', 'username') || payload.dig('user', 'id')}"

        if action["action_id"] == "silas_approve"
          invocation.approve!(by: who)
          render json: { replace_original: true, text: ":white_check_mark: Approved by @#{who}" }
        else
          invocation.decline!(reason: "declined in Slack", by: who)
          render json: { replace_original: true, text: ":x: Declined by @#{who}" }
        end
      rescue Silas::Error => e
        render json: { replace_original: false, text: "Could not record: #{e.message}" }
      end

      private

      def channel_class
        Silas.config.channel_resolver&.call("slack") or
          raise Silas::Error, "no app/agent/channels/slack.rb (Agent::Channels::Slack) defined"
      end
    end
  end
end
