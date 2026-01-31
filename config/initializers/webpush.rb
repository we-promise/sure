# frozen_string_literal: true

Rails.application.config.webpush = ActiveSupport::OrderedOptions.new

# VAPID keys for Web Push
# Generate with: Webpush.generate_key
Rails.application.config.webpush.vapid_public_key = ENV.fetch("VAPID_PUBLIC_KEY", nil)
Rails.application.config.webpush.vapid_private_key = ENV.fetch("VAPID_PRIVATE_KEY", nil)
Rails.application.config.webpush.vapid_subject = ENV.fetch("VAPID_SUBJECT", "mailto:support@example.com")

# Helper to check if push is configured
Rails.application.config.webpush.enabled = -> {
  Rails.application.config.webpush.vapid_public_key.present? &&
    Rails.application.config.webpush.vapid_private_key.present?
}
