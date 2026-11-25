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
# RubyLLM logs to Rails' logger but never logs request or response bodies, even at debug: they
# carry financial data. At debug it still logs each request line and an error's message, and a
# gateway can quote the key back there, so RubyLLM writes its configured keys as [FILTERED].
RubyLLM.configure do |config|
  config.logger = Rails.logger
  config.log_bodies = false
end
