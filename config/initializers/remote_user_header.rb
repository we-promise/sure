Rails.application.config.after_initialize do
  if Rails.application.config.remote_user_header_email.present? &&
     Rails.application.config.remote_user_trusted_proxies.nil?
    Rails.logger.warn(
      "[remote_user_header] REMOTE_USER_HEADER_EMAIL is set but " \
      "REMOTE_USER_TRUSTED_PROXIES is unset. The header will be trusted " \
      "from ANY source IP. Set REMOTE_USER_TRUSTED_PROXIES, or ensure " \
      "Sure is not reachable except via your authenticating reverse proxy."
    )
  end
end
