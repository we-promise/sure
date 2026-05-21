if ENV["SENTRY_DSN"].present?
  # Routes for which tracing/profiling are skipped because the data we get back
  # is low signal relative to the latency they add on every sampled request.
  # Add or remove patterns here as needed.
  SENTRY_LOW_VALUE_PATH_PATTERNS = [
    %r{\A/budgets(/|\z)},
    %r{\A/reports(/|\z)},
    %r{\A/?\z}, # root dashboard
    %r{\A/(rails/|cable|assets/|packs/)}, # rails internals
    %r{\A/up\z}, # healthcheck
  ].freeze

  Sentry.init do |config|
    config.dsn = ENV["SENTRY_DSN"]
    config.environment = ENV["RAILS_ENV"]
    config.breadcrumbs_logger = [ :active_support_logger, :http_logger ]
    config.enabled_environments = %w[production]

    # Log forwarding is OFF by default. The Sentry `:logger` patch wraps
    # `Logger#add` and ships *every* Rails log line (SQL Load lines included)
    # through Sentry on every request — sampled or not. That's the single
    # biggest reason "sentry-rails" keeps showing up in traces even after
    # dropping the sample rates. Set SENTRY_ENABLE_LOGS=true only when you're
    # actively chasing a log-only signal.
    if ENV["SENTRY_ENABLE_LOGS"] == "true"
      config.enable_logs = true
      config.enabled_patches = [ :logger ]
    end

    # Tracing/profiling sample rates can be tuned per-deploy without code
    # changes. Defaults are intentionally low so the average response time
    # chart reflects real application work, not profiler overhead.
    base_traces_rate   = (ENV["SENTRY_TRACES_SAMPLE_RATE"]   || "0.05").to_f
    base_profiles_rate = (ENV["SENTRY_PROFILES_SAMPLE_RATE"] || "0.01").to_f

    # `traces_sampler` lets us skip tracing entirely on specific paths.
    # When this returns 0, `Sentry::Rails::CaptureExceptions` still runs as
    # error-capture middleware but does NOT start a transaction / profile,
    # which removes the bulk of per-request Sentry overhead on hot endpoints.
    config.traces_sampler = ->(sampling_context) {
      env = sampling_context[:env] || {}
      path = env["PATH_INFO"].to_s

      next 0.0 if SENTRY_LOW_VALUE_PATH_PATTERNS.any? { |pat| path.match?(pat) }

      # Inherit the parent transaction's sampled state when present so
      # distributed traces stay consistent.
      if (parent = sampling_context[:parent_sampled])
        next parent ? 1.0 : 0.0
      end

      base_traces_rate
    }

    config.profiles_sample_rate = base_profiles_rate

    config.release = Rails.root.join(".sure-version").read.strip rescue nil
    config.profiler_class = Sentry::Vernier::Profiler
  end
end
