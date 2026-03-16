# frozen_string_literal: true

module FeatureFlags
  class << self
    def db_sso_providers?
      auth_source = ENV.fetch("AUTH_PROVIDERS_SOURCE") do
        Rails.configuration.app_mode.self_hosted? ? "db" : "yaml"
      end

      auth_source.to_s.downcase == "db"
    end

    def intro_ui?
      Rails.configuration.x.ui.default_layout.to_s.in?(%w[intro dashboard])
    end
  end
end
