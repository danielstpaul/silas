require "rails_helper"

# The silas:chat REPL: talk to the agent from the terminal, approvals prompt
# inline. IO is injected; the loop runs on the synchronous :inline adapter
# (same as the rake task) so every turn settles before the next prompt.
RSpec.describe Silas::Chat do
  around do |example|
    previous = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :inline
    example.run
  ensure
    ActiveJob::Base.queue_adapter = previous
  end

  def recording_tool(effect_mode: :transactional, approval: :never)
    executions = []
    tool = Object.new
    tool.define_singleton_method(:executions) { executions }
    tool.define_singleton_method(:effect_mode) { effect_mode }
    tool.define_singleton_method(:approval_policy) { approval }
    tool.define_singleton_method(:call) { |**args| executions << args; { "ok" => true } }
    tool
  end

  def configure!(engine, tool)
    Silas.configure do |c|
      c.engine = engine
      c.isolate_steps = false
      c.tool_resolver = ->(_name) { tool }
    end
  end

  def run_chat(script)
    output = StringIO.new
    described_class.new(io_in: StringIO.new(script), io_out: output, actor: "spec").run
    output.string
  end

  it "runs a turn and prints the agent's answer" do
    configure!(FakeEngine.new(&EngineScripts.n_tool_steps_then_done(1)), recording_tool)

    output = run_chat("hello\nexit\n")

    expect(output).to include("you>")
    expect(output).to include("✓ record")          # the settled tool call in the trace
    expect(output).to include("agent> done")
    expect(Silas::Turn.last.status).to eq("completed")
  end

  it "prompts for a parked approval inline and resumes on yes" do
    configure!(FakeEngine.new(&EngineScripts.n_tool_steps_then_done(1)),
               tool = recording_tool(approval: :always))

    output = run_chat("do the thing\ny\nexit\n")

    expect(output).to include("approval needed — record")
    expect(output).to include("agent> done")       # resumed after approval and finished
    expect(tool.executions.size).to eq(1)          # executed exactly once, after approval
    expect(Silas::Turn.last.status).to eq("completed")
  end

  it "leaves a skipped approval parked and blocks new input until settled" do
    configure!(FakeEngine.new(&EngineScripts.n_tool_steps_then_done(1)),
               tool = recording_tool(approval: :always))

    # skip the approval, try to send another message, then approve when re-prompted
    output = run_chat("do the thing\ns\nanother message\ny\nexit\n")

    expect(output).to include("left parked")
    expect(output).to include("still parked awaiting approval")
    expect(tool.executions.size).to eq(1)          # approved on the re-prompt
    expect(Silas::Turn.last.reload.status).to eq("completed")
  end

  it "prompts a budget-parked turn for a top-up and resumes on entry" do
    engine = FakeEngine.new do |context|
      if context[:index] < 2
        EngineScripts.result(blocks: [ { "type" => "text", "text" => "s#{context[:index]}" } ],
                             tool_calls: [ EngineScripts.tool_call("t#{context[:index]}") ]).tap do |r|
          r.usage[:input_tokens] = 5_000
        end
      else
        EngineScripts.result(blocks: [ { "type" => "text", "text" => "done" } ])
      end
    end
    allow(Silas).to receive(:agent).and_return(Silas::Agent.new("limits" => { "max_input_tokens" => 4_000 }))
    configure!(engine, recording_tool)

    # budget parks after step 0; user tops up to 100000 at the prompt
    output = run_chat("go\n100000\nexit\n")

    expect(output).to include("budget reached — max_input_tokens")
    expect(output).to include("agent> done")
    expect(Silas::Turn.last.reload.status).to eq("completed")
  end

  it "declines with a reason and the model sees the denial" do
    configure!(FakeEngine.new(&EngineScripts.n_tool_steps_then_done(1)),
               tool = recording_tool(approval: :always))

    output = run_chat("do the thing\nd\ntoo expensive\nexit\n")

    expect(tool.executions).to be_empty            # never executed
    invocation = Silas::ToolInvocation.last
    expect(invocation.approval_state).to eq("declined")
    expect(invocation.result).to eq({ "denied" => "too expensive" })
    expect(output).to include("agent>")            # loop continued to a final answer
  end
end
