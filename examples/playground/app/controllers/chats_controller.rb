# The customer-facing surface. Deliberately NOT the operator inbox: a shopper
# sees their own conversation and nothing else, while the shop's staff watch
# the same durable rows from /silas/inbox.
#
# One Silas session per browser session. Everything on screen — every message,
# every tool call, the approval card — is rendered from durable rows, so a
# refresh mid-turn (or a worker killed mid-turn) shows exactly the same state.
class ChatsController < ApplicationController
  before_action :load_session, only: %i[show create]

  def show
    @turns = @agent_session ? @agent_session.turns.includes(steps: :tool_invocations) : []
  end

  def create
    message = params[:message].to_s.strip
    return redirect_to(chat_path, alert: "Type a message first.") if message.empty?

    if @agent_session.nil?
      @agent_session = Silas.agent.start(input: message)
      session[:agent_session_id] = @agent_session.id
    else
      @agent_session.continue(input: message)
    end

    redirect_to chat_path
  rescue Silas::TurnInProgressError
    redirect_to chat_path, alert: "Still working on the last one — give it a second."
  end

  # Start over with a fresh agent session (the old one stays in the inbox —
  # nothing is deleted, this is a durable transcript).
  def destroy
    session.delete(:agent_session_id)
    redirect_to chat_path
  end

  private

  def load_session
    id = session[:agent_session_id]
    @agent_session = id && Silas::Session.find_by(id: id)
  end
end
