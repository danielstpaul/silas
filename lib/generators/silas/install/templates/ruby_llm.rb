# Point RubyLLM at your model provider. RubyLLM does NOT read provider API keys
# from the environment automatically — this initializer maps them in.
#
#   export ANTHROPIC_API_KEY=sk-ant-...
#
# Any provider RubyLLM supports works the same way (openai_api_key, etc.).
RubyLLM.configure do |c|
  # Silas never uses RubyLLM's acts_as_* ActiveRecord mixins (it owns its own
  # durable schema), so opt into the new API to silence the legacy deprecation
  # warning on every boot. Remove this line if THIS app uses acts_as_chat and
  # hasn't migrated yet — see https://rubyllm.com/upgrading-to-1-7/
  c.use_new_acts_as = true if c.respond_to?(:use_new_acts_as=)

  # A nil key is inert (Silas's boot check reports "no provider configured"),
  # so this needs no ENV guard — and the acts_as opt-in above must run even
  # on keyless boots, or the deprecation warning returns.
  c.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
  # The per-request timeout (seconds; RubyLLM default 300). Under streaming
  # this is an idle-between-chunks timeout — the hang protection for a stuck
  # provider connection.
  # c.request_timeout = 120
end
