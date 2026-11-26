# The order mailbox: one IMAP mailbox per instance that family members forward shop order emails
# to. Settings live in Setting (purchase_inbox_*), edited on the order mailbox settings page.
module PurchaseInbox
  Config = Data.define(
    :enabled, :host, :port, :ssl, :username, :password, :folder, :processed_folder,
    :shop_domains, :authserv_id, :require_sender_auth
  )

  module_function

  def config
    Config.new(
      enabled: Setting.purchase_inbox_enabled,
      host: Setting.purchase_inbox_host,
      port: Setting.purchase_inbox_port,
      ssl: Setting.purchase_inbox_ssl,
      username: Setting.purchase_inbox_username,
      password: Setting.purchase_inbox_password,
      folder: Setting.purchase_inbox_folder.presence || "INBOX",
      processed_folder: Setting.purchase_inbox_processed_folder.presence,
      shop_domains: Array(Setting.purchase_inbox_shop_domains).map { _1.to_s.strip.downcase }.compact_blank,
      authserv_id: Setting.purchase_inbox_authserv_id.to_s.strip.downcase.presence,
      require_sender_auth: Setting.purchase_inbox_require_sender_auth
    )
  end

  # PURCHASE_INBOX_IMAP_PORT; empty or missing means IMAPS (993), never port 0.
  def env_port(value)
    value.to_s.strip.presence&.to_i || 993
  end

  # PURCHASE_INBOX_IMAP_SSL; only an explicit "false" turns TLS off, so an empty variable
  # doesn't send the mailbox password in clear text.
  def env_ssl(value)
    !value.to_s.strip.casecmp?("false")
  end

  # Enough settings to log in, and a trusted authentication host when senders must be verified.
  def configured?(config = self.config)
    config.enabled && config.host.present? && config.username.present? && config.password.present? &&
      (!config.require_sender_auth || config.authserv_id.present?)
  end

  # Removes the mailbox password from an error message before it is stored or shown.
  def redact(message, password = Setting.purchase_inbox_password)
    password.present? ? message.to_s.gsub(password, "[FILTERED]") : message.to_s
  end

  def record_poll!(error: nil)
    Setting.purchase_inbox_last_polled_at = Time.current
    Setting.purchase_inbox_last_error = error
  end
end
