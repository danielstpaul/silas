module Silas
  module Inbox
    # The cross-agent held queue: everything awaiting a person, in one place,
    # ordered by expiry (the card about to become a failed turn outranks the
    # one with six days left). One screen instead of a filter per agent.
    class HeldController < BaseController
      def index
        @invocations = Silas::ToolInvocation
                       .where(approval_state: "required")
                       .includes(turn: :session)
                       .order(:approval_expires_at, :id)
        @by_agent = @invocations.group_by { |inv| inv.turn.session.agent_name }
      end
    end
  end
end
