require "sidekiq/web"

if Rails.env.production?
  Sidekiq::Web.use(Rack::Auth::Basic) do |username, password|
    configured_username = ::Digest::SHA256.hexdigest(ENV.fetch("SIDEKIQ_WEB_USERNAME", "sure"))
    configured_password = ::Digest::SHA256.hexdigest(ENV.fetch("SIDEKIQ_WEB_PASSWORD", "sure"))

    ActiveSupport::SecurityUtils.secure_compare(::Digest::SHA256.hexdigest(username), configured_username) &&
      ActiveSupport::SecurityUtils.secure_compare(::Digest::SHA256.hexdigest(password), configured_password)
  end
end

# Configure Redis connection for Sidekiq
# Supports both Redis Sentinel (for HA) and direct Redis URL
redis_config = if ENV["REDIS_SENTINEL_HOSTS"].present?
  # Redis Sentinel configuration for high availability
  # REDIS_SENTINEL_HOSTS should be comma-separated list: "host1:port1,host2:port2,host3:port3"
  sentinels = ENV["REDIS_SENTINEL_HOSTS"].split(",").filter_map do |host_port|
    parts = host_port.strip.split(":", 2)
    host = parts[0]&.strip
    port_str = parts[1]&.strip

    next if host.blank?

    # Parse port with validation, default to 26379 if invalid or missing
    port = if port_str.present?
      port_int = port_str.to_i
      (port_int > 0 && port_int <= 65535) ? port_int : 26379
    else
      26379
    end

    { host: host, port: port }
  end

  if sentinels.empty?
    Rails.logger.warn("REDIS_SENTINEL_HOSTS is set but no valid sentinel hosts found, falling back to REDIS_URL")
    { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
  else
    {
      url: "redis://#{ENV.fetch('REDIS_SENTINEL_MASTER', 'mymaster')}/0",
      sentinels: sentinels,
      password: ENV["REDIS_PASSWORD"],
      sentinel_username: ENV.fetch("REDIS_SENTINEL_USERNAME", "default"),
      sentinel_password: ENV["REDIS_PASSWORD"],
      role: :master,
      # Recommended timeouts for Sentinel
      connect_timeout: 0.2,
      read_timeout: 1,
      write_timeout: 1,
      reconnect_attempts: 3
    }
  end
else
  # Standard Redis URL configuration (no Sentinel)
  { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
end

Sidekiq.configure_server do |config|
  config.redis = redis_config

  # Initialize auto-sync scheduler when Sidekiq server starts
  config.on(:startup) do
    AutoSyncScheduler.sync!
    Rails.logger.info("[AutoSyncScheduler] Initialized sync_all_accounts cron job")
  rescue => e
    Rails.logger.error("[AutoSyncScheduler] Failed to initialize: #{e.message}")
  end
end

Sidekiq.configure_client do |config|
  config.redis = redis_config
end

Sidekiq::Cron.configure do |config|
  # 10 min "catch-up" window in case worker process is re-deploying when cron tick occurs
  config.reschedule_grace_period = 600
end
