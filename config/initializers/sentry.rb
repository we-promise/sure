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

    # Set traces_sample_rate to 1.0 to capture 100%
    # of transactions for performance monitoring.
    # We recommend adjusting this value in production.
    # Lower sampling keeps performance overhead down on hot paths like transactions#index.
    # Use Skylight for steady-state APM; keep Sentry for errors and light trace sampling.
    config.traces_sample_rate = 0.05
    config.profiles_sample_rate = 0

    config.release = Rails.root.join(".sure-version").read.strip rescue nil
    config.profiler_class = Sentry::Vernier::Profiler
  end
end
