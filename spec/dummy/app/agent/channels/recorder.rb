# A test channel that records outbound deliveries in-process, so channel specs
# can assert deliver_answer/deliver_approval without a real transport.
class Agent::Channels::Recorder < Silas::Channel
  def self.answers = @answers ||= []
  def self.approvals = @approvals ||= []
  def self.reset! = (answers.clear; approvals.clear)

  def deliver_answer(session:, text:)
    self.class.answers << { session_id: session.id, text: text }
  end

  def deliver_approval(session:, invocation:)
    self.class.approvals << { session_id: session.id, invocation_id: invocation.id, tool: invocation.tool_name }
  end
end
