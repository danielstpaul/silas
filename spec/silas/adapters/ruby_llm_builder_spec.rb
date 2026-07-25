require "rails_helper"

# The adapter uses RubyLLM's Chat as a builder and Provider#complete as the
# executor. The executor half needs a network, but the BUILDER half doesn't —
# and it is where the version-sensitive calls live (with_tools, with_schema,
# Content::Raw, ToolCall). Everything here runs against the real RubyLLM with no
# API key and no HTTP, so a renamed builder method fails here first.
RSpec.describe Silas::Adapters::RubyLLM, "building a chat" do
  let(:adapter) { described_class.new }
  let(:model) { Silas.config.default_model }

  # Resolving a model instantiates its provider, which refuses to exist without
  # a key. Nothing here sends a request, so any string will do.
  around do |example|
    previous = ::RubyLLM.config.anthropic_api_key
    ::RubyLLM.config.anthropic_api_key = "test-key-never-sent"
    example.run
  ensure
    ::RubyLLM.config.anthropic_api_key = previous
  end

  def build(**overrides)
    context = { turn: nil, index: 0, model: model, system: nil,
                final_answer: nil, tools: [], messages: [], limits: {} }
    adapter.send(:build_chat, context.merge(overrides))
  end

  it "resolves the model through RubyLLM's registry" do
    expect(build.model.id).to eq(model)
  end

  it "raises a Silas error naming the fix for a model outside the registry" do
    expect { build(model: "definitely-not-a-model-xyz") }
      .to raise_error(Silas::Error, /not in ruby_llm's model registry.*refresh/m)
  end

  it "puts the instructions on the chat as a system message" do
    chat = build(system: "you are a support agent")
    expect(chat.messages.map(&:role)).to include(:system)
    expect(chat.messages.find { |m| m.role == :system }.content.to_s)
      .to include("you are a support agent")
  end

  it "leaves the chat without a system message when there are no instructions" do
    expect(build.messages.map(&:role)).not_to include(:system)
  end

  it "registers each tool so the provider can render its schema" do
    tools = [
      { "name" => "issue_refund", "description" => "refund an order",
        "input_schema" => { "type" => "object", "properties" => { "amount" => { "type" => "integer" } } } },
      { "name" => "find_customer", "description" => "look a customer up",
        "input_schema" => { "type" => "object" } }
    ]
    chat = build(tools: tools)

    expect(chat.tools.keys).to contain_exactly(:issue_refund, :find_customer)
    refund = chat.tools[:issue_refund]
    expect(refund.description).to eq("refund an order")
    expect(refund.params_schema.dig("properties", "amount", "type")).to eq("integer")
  end

  it "normalises the final_answer schema onto the chat" do
    chat = build(final_answer: { "type" => "object", "properties" => { "verdict" => { "type" => "string" } } })
    # RubyLLM wraps the raw schema in its own payload shape; what matters is
    # that the definition survives into it.
    expect(chat.schema).to be_present
    expect(chat.schema.to_s).to include("verdict")
  end

  it "leaves schema nil when the agent declares no final_answer" do
    expect(build.schema).to be_nil
  end

  describe "replaying Silas's rows into provider messages" do
    it "replays user and assistant turns in order" do
      chat = build(messages: [
        { role: "user", content: "hello" },
        { role: "assistant", content: [ { "type" => "text", "text" => "hi there" } ] },
        { role: "user", content: "again" }
      ])

      expect(chat.messages.map(&:role)).to eq(%i[user assistant user])
      expect(chat.messages[1].content.to_s).to eq("hi there")
    end

    it "rebuilds assistant tool calls as RubyLLM ToolCalls" do
      chat = build(messages: [
        { role: "user", content: "refund it" },
        { role: "assistant", content: [
          { "type" => "text", "text" => "on it" },
          { "type" => "tool_call", "id" => "t0", "name" => "issue_refund", "arguments" => { "amount" => 500 } }
        ] }
      ])

      calls = chat.messages.last.tool_calls
      expect(calls.keys).to eq([ "t0" ])
      expect(calls["t0"]).to be_a(::RubyLLM::ToolCall)
      expect(calls["t0"]).to have_attributes(name: "issue_refund", arguments: { "amount" => 500 })
    end

    # Anthropic rejects a turn whose parallel tool_results are split across
    # messages — this batching is load-bearing, not tidiness.
    it "batches consecutive tool results into one message" do
      chat = build(messages: [
        { role: "user", content: "do both" },
        { role: "assistant", content: [
          { "type" => "tool_call", "id" => "t0", "name" => "a", "arguments" => {} },
          { "type" => "tool_call", "id" => "t1", "name" => "b", "arguments" => {} }
        ] },
        { role: "tool", tool_call_id: "t0", content: { "ok" => true } },
        { role: "tool", tool_call_id: "t1", content: { "ok" => false } }
      ])

      tool_messages = chat.messages.select { |m| m.role == :tool }
      expect(tool_messages.size).to eq(1)

      raw = tool_messages.first.content
      expect(raw).to be_a(::RubyLLM::Content::Raw)
      expect(raw.value.map { |b| b[:tool_use_id] }).to eq(%w[t0 t1])
      expect(raw.value.first[:type]).to eq("tool_result")
    end

    it "carries the first tool_call_id so the batch is addressable" do
      chat = build(messages: [
        { role: "user", content: "x" },
        { role: "tool", tool_call_id: "t9", content: { "ok" => true } }
      ])
      expect(chat.messages.last.tool_call_id).to eq("t9")
    end
  end

  # The closest thing to a smoke test without a key: take what the adapter
  # built and render it through the provider's own payload builder — the exact
  # call Provider#complete makes before it hits the wire. A tool that never
  # reaches the request, or a tool_result the provider would reject, fails
  # here rather than in production.
  describe "the request the provider would send" do
    let(:provider) { adapter.send(:provider_for, build.model) }

    # render_payload is private (module_function). Reaching in is deliberate and
    # test-only: production never calls it, but asserting on the rendered
    # request is the only way to check the wire shape without a network. If it
    # ever disappears, these specs fail and nothing shipping does.
    def render(chat)
      provider.send(
        :render_payload,
        chat.messages, tools: chat.tools, temperature: nil,
        model: chat.model, stream: false, schema: chat.schema, tool_prefs: chat.tool_prefs
      )
    end

    it "advertises every tool with its schema" do
      chat = build(tools: [
        { "name" => "issue_refund", "description" => "refund an order",
          "input_schema" => { "type" => "object", "properties" => { "amount" => { "type" => "integer" } } } }
      ])
      payload = render(chat)

      expect(payload[:tools].map { |t| t[:name] }).to eq([ "issue_refund" ])
      expect(payload[:tools].first[:description]).to eq("refund an order")
      expect(payload[:tools].first[:input_schema]).to include("properties")
    end

    it "sends the instructions as Anthropic's top-level system field, not a message" do
      payload = render(build(system: "you are a support agent"))

      expect(payload[:system].to_s).to include("you are a support agent")
      expect(payload[:messages].map { |m| m[:role] }).not_to include("system")
    end

    it "puts parallel tool results in ONE user message, as Anthropic requires" do
      chat = build(messages: [
        { role: "user", content: "do both" },
        { role: "assistant", content: [
          { "type" => "tool_call", "id" => "t0", "name" => "a", "arguments" => {} },
          { "type" => "tool_call", "id" => "t1", "name" => "b", "arguments" => {} }
        ] },
        { role: "tool", tool_call_id: "t0", content: { "ok" => true } },
        { role: "tool", tool_call_id: "t1", content: { "ok" => false } }
      ])
      payload = render(chat)

      # assistant tool_use turn, then a single user turn carrying both results
      results = payload[:messages].last
      expect(results[:role]).to eq("user")
      ids = results[:content].select { |b| b[:type] == "tool_result" }.map { |b| b[:tool_use_id] }
      expect(ids).to eq(%w[t0 t1])

      # every tool_use has a matching tool_result — the provider 400s otherwise
      uses = payload[:messages].flat_map { |m| Array(m[:content]) }
                               .select { |b| b.is_a?(Hash) && b[:type] == "tool_use" }.map { |b| b[:id] }
      expect(uses).to eq(ids)
    end

    it "renders the final_answer schema into the structured-output field" do
      payload = render(build(final_answer: {
        "type" => "object", "properties" => { "verdict" => { "type" => "string" } }
      }))
      expect(payload[:output_config].to_s).to include("verdict")
    end
  end
end
