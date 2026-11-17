# RubyLLM is the HTTP layer under Sure's AI transports (app/models/ai/transport). Nothing calls
# RubyLLM's global configuration: every request goes through a RubyLLM.context built per
# endpoint by Ai::Transport::RubyLlmAdapter, so no key, URL, timeout or retry is set here.
#
# RubyLLM's railtie, loaded by Bundler, also:
# - adds `acts_as_chat`/`acts_as_message` to ActiveRecord::Base (Sure doesn't use them);
# - sets ActiveSupport::Notifications as the instrumenter, so `*.ruby_llm` events publish in
#   this process (Ai::Instrumentation::UsageSubscriber reads `usage.ruby_llm`);
# - adds an after_destroy hook to Active Storage blobs, guarded by `ruby_llm_provider_files`,
#   a table Sure doesn't create;
# - installs its usage ledger. Sure records usage in `llm_usages` and never creates
#   `ruby_llm_usages`, so the ledger writes nothing (test/models/ai/ruby_llm_setup_test.rb).
#
# Don't add `ruby_llm-monitoring`: it rewrites app-wide inflections, after which Zeitwerk
# expects `LLMUsage` instead of `LlmUsage`.
#
# RubyLLM logs to Rails' logger, but never at debug: at debug it logs response bodies and raw
# exceptions through Faraday, before Ai::Instrumentation::Redactor sees them, and a gateway can
# quote a key back in an error. Its info and warn lines carry no request or response content.
class RubyLlmLogger < SimpleDelegator
  def debug(*) = true
  def debug? = false
  def level = [ __getobj__.level, Logger::INFO ].max
end

RubyLLM.configure do |config|
  config.logger = RubyLlmLogger.new(Rails.logger)
end
