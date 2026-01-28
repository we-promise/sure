# frozen_string_literal: true

Rails.configuration.x.auth ||= ActiveSupport::OrderedOptions.new

begin
  raw_auth_config = Rails.application.config_for(:auth)
rescue RuntimeError, Errno::ENOENT, Psych::SyntaxError => e
  Rails.logger.warn("Auth config not loaded: #{e.class} - #{e.message}")
  raw_auth_config = {}
end

auth_config = raw_auth_config.deep_symbolize_keys

Rails.configuration.x.auth.local_login_enabled = auth_config.dig(:local_login, :enabled)
Rails.configuration.x.auth.local_admin_override_enabled = auth_config.dig(:local_login, :admin_override_enabled)

Rails.configuration.x.auth.jit_mode = auth_config.dig(:jit, :mode) || "create_and_link"

raw_domains = auth_config.dig(:jit, :allowed_oidc_domains).to_s
Rails.configuration.x.auth.allowed_oidc_domains = raw_domains.split(",").map(&:strip).reject(&:empty?)

Rails.configuration.x.auth.providers = (auth_config[:providers] || [])

# These will be populated by the OmniAuth initializer once providers are
# successfully registered.
Rails.configuration.x.auth.sso_providers ||= []
