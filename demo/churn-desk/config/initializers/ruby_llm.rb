# RubyLLM does not read ANTHROPIC_API_KEY automatically — map it in.
#   export ANTHROPIC_API_KEY=sk-ant-...
RubyLLM.configure do |c|
  c.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
end if ENV["ANTHROPIC_API_KEY"].present?
