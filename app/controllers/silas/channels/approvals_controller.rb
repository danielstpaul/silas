module Silas
  module Channels
    # Email approve/decline links land here. The signed token carries the
    # invocation id + action (no session state in the URL); a GET shows a
    # confirm page, a POST performs the action via the existing approve!/decline!.
    class ApprovalsController < BaseController
      def show
        @claim = Silas::Channel.verify_token(params[:token])
        return render(:error, status: :unprocessable_entity) unless @claim

        @invocation = Silas::ToolInvocation.find_by(id: @claim["id"])
        @action = @claim["action"]
        render :show
      end

      def update
        claim = Silas::Channel.verify_token(params[:token])
        return render(:error, status: :unprocessable_entity) unless claim

        invocation = Silas::ToolInvocation.find(claim["id"])
        if claim["action"] == "approve"
          invocation.approve!(by: "email")
        else
          invocation.decline!(reason: "declined by email", by: "email")
        end
        @action = claim["action"]
        render :done
      rescue Silas::Error => e
        @message = e.message
        render :error, status: :unprocessable_entity
      end
    end
  end
end
