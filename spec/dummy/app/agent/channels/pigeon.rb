# A filled-in version of what `rails g silas:channel pigeon` scaffolds: the
# outbound half. Its partner controller lives in
# spec/dummy/app/controllers/agent/channels/pigeon_controller.rb.
#
# This fixture exists to prove the generated SHAPE works end to end in a real
# Rails app — both autoload roots contributing to Agent::Channels, the signed
# approval link, and dispatch through the host's own route.
class Agent::Channels::Pigeon < Silas::Channel
  def self.sent = @sent ||= []
  def self.reset! = sent.clear

  def deliver_answer(session:, text:)
    self.class.sent << { to: session.metadata.dig("pigeon", "coop"), text: text }
  end

  def deliver_approval(session:, invocation:)
    self.class.sent << {
      to: session.metadata.dig("pigeon", "coop"),
      approve: Silas::Channel.approval_url(invocation, :approve),
      decline: Silas::Channel.approval_url(invocation, :decline)
    }
  end
end
