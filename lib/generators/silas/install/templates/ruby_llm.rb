# Point RubyLLM at your model provider. RubyLLM does NOT read provider API keys
# from the environment automatically — this initializer maps them in.
#
#   export ANTHROPIC_API_KEY=sk-ant-...
#
# Any provider RubyLLM supports works the same way (openai_api_key, etc.).
RubyLLM.configure do |c|
  c.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
  # The per-request timeout (seconds; RubyLLM default 300). Under streaming
  # this is an idle-between-chunks timeout — the hang protection for a stuck
  # provider connection.
  # c.request_timeout = 120
end if ENV["ANTHROPIC_API_KEY"].present?
