if ENV["SENTRY_DSN"].present?
  Sentry.init do |config|
    config.dsn = ENV["SENTRY_DSN"]
    config.environment = ENV["RAILS_ENV"]
    config.breadcrumbs_logger = [ :active_support_logger, :http_logger ]
    config.enabled_environments = %w[production]

    # Enable sending logs to Sentry
    config.enable_logs = true
    # Patch Ruby logger to forward logs
    config.enabled_patches = [ :logger ]

    # AI Agent Monitoring (see docs/monitoring/sentry-ai-monitoring.md):
    # gen_ai.* spans are emitted via LlmInstrumentation. Prompt/response
    # content is PII and is only attached when explicitly opted in.
    config.send_default_pii = ENV["SENTRY_SEND_DEFAULT_PII"] == "true"

    # Base sample rate for performance monitoring. Agent runs are sampled as
    # complete span trees — if the root transaction is dropped, every child
    # gen_ai span is lost with it — so AI-related transactions are kept at
    # 100% while everything else uses the base rate.
    base_traces_sample_rate = ENV.fetch("SENTRY_TRACES_SAMPLE_RATE", "0.25").to_f

    # Background jobs and controllers whose transactions contain LLM calls.
    ai_transaction_pattern = Regexp.union(
      "AssistantResponseJob",
      "AutoCategorizeJob",
      "AutoDetectMerchantsJob",
      "EnhanceProviderMerchantsJob",
      "ProcessPdfJob",
      "ChatsController",
      "MessagesController"
    )

    config.traces_sampler = lambda do |sampling_context|
      transaction_context = sampling_context[:transaction_context] || {}
      op = transaction_context[:op].to_s
      name = transaction_context[:name].to_s

      # Standalone gen_ai root spans and AI-related transactions: always keep.
      next 1.0 if op.start_with?("gen_ai")
      next 1.0 if ai_transaction_pattern.match?(name)

      # Continue the parent's decision for distributed traces.
      parent_sampled = sampling_context[:parent_sampled]
      next(parent_sampled ? 1.0 : 0.0) unless parent_sampled.nil?

      base_traces_sample_rate
    end

    # Set profiles_sample_rate to profile 100%
    # of sampled transactions.
    # We recommend adjusting this value in production.
    config.profiles_sample_rate = 0.25

    config.release = Rails.root.join(".sure-version").read.strip rescue nil
    config.profiler_class = Sentry::Vernier::Profiler
  end
end
