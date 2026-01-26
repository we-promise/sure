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
#
# NOTE: The :db_sso_providers feature flag is now managed via the AUTH_PROVIDERS_SOURCE
# environment variable to avoid expensive database queries during initialization.
# The ProviderLoader service reads AUTH_PROVIDERS_SOURCE directly, so we no longer
# need to initialize this flag here, which eliminates slow LEFT OUTER JOIN queries
# on the flipper_features and flipper_gates tables during boot.
#
# If you need to manage this flag through the Flipper UI or programmatically,
# you can uncomment the code below, but be aware it will add ~1-2 seconds to
# application boot time due to database queries.
#
# unless Rails.env.test?
#   begin
#     auth_source = ENV.fetch("AUTH_PROVIDERS_SOURCE") do
#       Rails.configuration.app_mode.self_hosted? ? "db" : "yaml"
#     end.downcase
#
#     Flipper.add(:db_sso_providers) unless Flipper.exist?(:db_sso_providers)
#
#     if auth_source == "db"
#       Flipper.enable(:db_sso_providers)
#     else
#       Flipper.disable(:db_sso_providers)
#     end
#   rescue ActiveRecord::NoDatabaseError, ActiveRecord::StatementInvalid
#     # Database not ready yet
#   rescue StandardError => e
#     Rails.logger.warn("[Flipper] Error initializing feature flags: #{e.message}")
#   end
# end
