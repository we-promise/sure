# frozen_string_literal: true

# Reverse-proxy header authentication is easy to misconfigure in ways that are
# invisible at runtime: the login page simply keeps appearing. Surface the
# config-level mistakes once at boot so an operator has something to search for.
Rails.application.config.after_initialize do
  config = Rails.application.config

  next if config.remote_user_header_email.blank?

  unless config.app_mode.self_hosted?
    Rails.logger.warn(
      "[remote_user_header] REMOTE_USER_HEADER_EMAIL is set but this instance is " \
      "not self-hosted. The header will be ignored on every request."
    )
  end

  if config.remote_user_trusted_proxies_invalid.present?
    Rails.logger.warn(
      "[remote_user_header] ignoring unparseable REMOTE_USER_TRUSTED_PROXIES " \
      "entries: #{config.remote_user_trusted_proxies_invalid.join(', ')}. " \
      "Each entry must be an IP or CIDR (e.g. 10.0.0.5 or 172.18.0.0/16)."
    )
  end

  if config.remote_user_trusted_proxies.empty?
    Rails.logger.warn(
      "[remote_user_header] REMOTE_USER_TRUSTED_PROXIES resolved to an empty " \
      "allowlist, so the header will be ignored on every request. Unset the " \
      "variable to fall back to the loopback default (127.0.0.0/8,::1/128)."
    )
  end

  if config.remote_user_shared_secret.blank?
    Rails.logger.warn(
      "[remote_user_header] REMOTE_USER_SHARED_SECRET is unset. The source-IP " \
      "allowlist is the only gate on the header; anything that can reach Sure " \
      "from a trusted peer address can assume any account."
    )
  end

  if config.remote_user_logout_url_invalid.present?
    Rails.logger.warn(
      "[remote_user_header] ignoring REMOTE_USER_LOGOUT_URL " \
      "#{config.remote_user_logout_url_invalid.inspect}: it must be an " \
      "http:// or https:// URL."
    )
  end
end
