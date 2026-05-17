require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Sure
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 7.2

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
    config.remote_user_trusted_proxies = (ENV["REMOTE_USER_TRUSTED_PROXIES"].presence || "127.0.0.0/8,::1/128")
      .split(",")
      .map(&:strip)
      .reject(&:empty?)
      .filter_map { |s| IPAddr.new(s) rescue nil }
    # Optional shared-secret gate: when REMOTE_USER_SHARED_SECRET is set,
    # the proxy must echo it in the configured sibling header. Unset means
    # no shared-secret check (the IP allowlist remains the only gate).
    config.remote_user_shared_secret = ENV["REMOTE_USER_SHARED_SECRET"].presence
    config.remote_user_shared_secret_header = ENV.fetch("REMOTE_USER_SHARED_SECRET_HEADER", "X-Remote-User-Secret")

    # Self hosters can optionally set their own encryption keys if they want to use ActiveRecord encryption.
    if Rails.application.credentials.active_record_encryption.present?
      config.active_record.encryption = Rails.application.credentials.active_record_encryption
    end

    config.view_component.preview_controller = "LookbooksController"
    config.lookbook.preview_display_options = {
      theme: [ "light", "dark" ] # available in view as params[:theme]
    }

    # Enable Skylight instrumentation for ActiveJob (background workers)
    config.skylight.probes << "active_job" if defined?(Skylight)

    # Enable Rack::Attack middleware for API rate limiting
    config.middleware.use Rack::Attack

    config.x.ui = ActiveSupport::OrderedOptions.new
    default_layout = ENV.fetch("DEFAULT_UI_LAYOUT", "dashboard")
    config.x.ui.default_layout = default_layout.in?(%w[dashboard intro]) ? default_layout : "dashboard"
    # Handle OmniAuth/OIDC errors gracefully (must be before OmniAuth middleware)
    require_relative "../app/middleware/omniauth_error_handler"
    config.middleware.use OmniauthErrorHandler
  end
end
