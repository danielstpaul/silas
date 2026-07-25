# The inbound half of the generated channel shape (see pigeon.rb). Kept
# deliberately close to lib/generators/silas/channel/templates/controller.rb so
# a request spec exercises what a user actually gets.
class Agent::Channels::PigeonController < ActionController::Base
  skip_forgery_protection

  before_action :verify_webhook!

  def create
    thread_key = params[:conversation_id].to_s
    text       = params[:text].to_s
    return head(:ok) if thread_key.blank? || text.blank?

    Agent::Channels::Pigeon.dispatch(
      thread_key: thread_key,
      input: text,
      metadata: { "pigeon" => { "coop" => thread_key } }
    )
    head :ok
  rescue Silas::TurnInProgressError
    head :ok
  end

  private

  def verify_webhook!
    ok = Silas::Webhook.verify_hmac(
      secret: "coo-coo",
      signature: request.headers["X-Signature"],
      payload: request.raw_post,
      timestamp: request.headers["X-Signature-Timestamp"],
      prefix: "sha256="
    )
    head(:unauthorized) unless ok
    ok
  end
end
