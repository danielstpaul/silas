# Point RubyLLM at your Anthropic key. RubyLLM does NOT read ANTHROPIC_API_KEY
# automatically — this initializer maps it in. Any provider RubyLLM supports
# works; the demo's agent.yml uses a Claude model, so set the Anthropic key:
#
#   export ANTHROPIC_API_KEY=sk-ant-...
#
RubyLLM.configure do |c|
  c.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
end if ENV["ANTHROPIC_API_KEY"].present?
