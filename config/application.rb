require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Sure
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks generators])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # TODO: This is here for incremental adoption of localization.  This can be removed when all translations are implemented.
    config.i18n.fallbacks = true

    config.app_mode = (ENV["SELF_HOSTED"] == "true" || ENV["SELF_HOSTING_ENABLED"] == "true" ? "self_hosted" : "managed").inquiry

    config.remote_user_header_email = ENV["REMOTE_USER_HEADER_EMAIL"]
    # Default to loopback only so a misconfigured deployment fails closed
    # at first login attempt rather than silently honoring the header from
    # any source. Set REMOTE_USER_TRUSTED_PROXIES to widen the allowlist.
    # Only an *absent* variable takes that default: setting it to an empty
    # value resolves to an empty allowlist, which is the documented way to
    # switch the header off without unsetting REMOTE_USER_HEADER_EMAIL.
    parsed_trusted_proxies = (ENV["REMOTE_USER_TRUSTED_PROXIES"] || "127.0.0.0/8,::1/128")
      .split(",")
      .map(&:strip)
      .reject(&:empty?)
      .map { |entry| [ entry, (IPAddr.new(entry) rescue nil) ] }
    config.remote_user_trusted_proxies = parsed_trusted_proxies.filter_map(&:last)
    # Entries that don't parse are dropped rather than raising at boot, but a
    # typo'd CIDR would otherwise silently shrink the allowlist. Keep the bad
    # entries so config/initializers/remote_user_header.rb can warn about them.
    config.remote_user_trusted_proxies_invalid = parsed_trusted_proxies.reject(&:last).map(&:first)
    # Optional shared-secret gate: when REMOTE_USER_SHARED_SECRET is set,
    # the proxy must echo it in the configured sibling header. Unset means
    # no shared-secret check (the IP allowlist remains the only gate).
    config.remote_user_shared_secret = ENV["REMOTE_USER_SHARED_SECRET"].presence
    config.remote_user_shared_secret_header = ENV.fetch("REMOTE_USER_SHARED_SECRET_HEADER", "X-Remote-User-Secret")
    # When false, the header can only log in users that already exist. Pairs
    # with AUTH_JIT_MODE=link_only; this knob is the one that also survives a
    # deactivate + purge, since a purged user is indistinguishable from a new one.
    config.remote_user_allow_jit = ENV.fetch("REMOTE_USER_ALLOW_JIT", "true") == "true"
    # Optional proxy sign-out URL. Without it, logging out only clears the local
    # session and the next navigation re-authenticates from the header.
    config.remote_user_logout_url = ENV["REMOTE_USER_LOGOUT_URL"].presence
    # Assign unconditionally. config/initializers/remote_user_header.rb reads
    # this on every boot where the header is enabled, and
    # Rails::Application::Configuration#method_missing raises NoMethodError for
    # an attribute that was never assigned rather than returning nil.
    config.remote_user_logout_url_invalid = nil
    if config.remote_user_logout_url.present? &&
       !config.remote_user_logout_url.match?(%r{\Ahttps?://}i)
      config.remote_user_logout_url_invalid = config.remote_user_logout_url
      config.remote_user_logout_url = nil
    end

    # Self hosters can optionally set their own encryption keys if they want to use ActiveRecord encryption.
    if Rails.application.credentials.active_record_encryption.present?
      config.active_record.encryption = Rails.application.credentials.active_record_encryption
    end

    config.view_component.preview_controller = "LookbooksController"
    config.lookbook.preview_display_options = {
      theme: [ "light", "dark" ] # available in view as params[:theme]
    }

    # Enable Skylight instrumentation for ActiveJob (background workers)
    # Developers can opt-in to Skylight locally by setting SKYLIGHT_ENABLED=true
    if defined?(Skylight) && config.respond_to?(:skylight)
      config.skylight.probes << "active_job"
      if ENV["SKYLIGHT_ENABLED"] == "true"
        config.skylight.environments += [ "development" ]
      end
    end

    # Enable Rack::Attack middleware for API rate limiting
    config.middleware.use Rack::Attack

    config.x.ui = ActiveSupport::OrderedOptions.new
    default_layout = ENV.fetch("DEFAULT_UI_LAYOUT", "dashboard")
    config.x.ui.default_layout = default_layout.in?(%w[dashboard intro]) ? default_layout : "dashboard"

    config.x.debug_log = ActiveSupport::OrderedOptions.new
    retention_days = ENV.fetch("DEBUG_LOG_RETENTION_DAYS", "90").to_i
    config.x.debug_log.retention_days = retention_days.positive? ? retention_days : 90

    # Handle OmniAuth/OIDC errors gracefully (must be before OmniAuth middleware)
    require_relative "../app/middleware/omniauth_error_handler"
    config.middleware.use OmniauthErrorHandler
  end
end
