# frozen_string_literal: true

require "flipper"
require "flipper/adapters/active_record"
require "flipper/adapters/memory"

# Configure Flipper with ActiveRecord adapter for database-backed feature flags
# Falls back to memory adapter if tables don't exist yet (during migrations)
Flipper.configure do |config|
  config.adapter do
    begin
      Flipper::Adapters::ActiveRecord.new
    rescue ActiveRecord::NoDatabaseError, ActiveRecord::StatementInvalid, NameError
      # Tables don't exist yet, use memory adapter as fallback
      Flipper::Adapters::Memory.new
    end
  end
end

# Initialize feature flags IMMEDIATELY (not in after_initialize)
# This must happen before OmniAuth initializer runs
unless Rails.env.test?
  begin
    # Feature flag to control SSO provider source (YAML vs DB)
    # ENV: AUTH_PROVIDERS_SOURCE=db|yaml
    # Default: "db" for self-hosted, "yaml" for managed
    auth_source = ENV.fetch("AUTH_PROVIDERS_SOURCE") do
      Rails.configuration.app_mode.self_hosted? ? "db" : "yaml"
    end.downcase

    # Ensure feature exists before enabling/disabling
    Flipper.add(:db_sso_providers) unless Flipper.exist?(:db_sso_providers)

    if auth_source == "db"
      Flipper.enable(:db_sso_providers)
    else
      Flipper.disable(:db_sso_providers)
    end
  rescue ActiveRecord::NoDatabaseError, ActiveRecord::StatementInvalid
    # Database not ready yet (e.g., during initial setup or migrations)
    # This is expected during db:create or initial setup
  rescue StandardError => e
    Rails.logger.warn("[Flipper] Error initializing feature flags: #{e.message}")
  end
end
