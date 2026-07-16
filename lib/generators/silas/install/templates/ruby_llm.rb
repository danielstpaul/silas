# Point RubyLLM at your model provider. RubyLLM does NOT read provider API keys
# from the environment automatically — this initializer maps them in.
#
#   export ANTHROPIC_API_KEY=sk-ant-...
#
# Any provider RubyLLM supports works the same way (openai_api_key, etc.).
RubyLLM.configure do |c|
  c.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
end if ENV["ANTHROPIC_API_KEY"].present?
