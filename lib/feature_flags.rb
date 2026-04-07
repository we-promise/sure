# frozen_string_literal: true

module FeatureFlags
  class << self
    def db_sso_providers?
      auth_source = ENV["AUTH_PROVIDERS_SOURCE"]
      return auth_source.to_s.downcase == "db" if auth_source.present?

      # In production, prefer YAML by default so boot-time tasks (e.g. db:prepare)
      # do not attempt to query SSO provider tables before migrations run.
      return false if Rails.env.production?

      auth_source = Rails.configuration.app_mode.self_hosted? ? "db" : "yaml"

      auth_source.to_s.downcase == "db"
    end

    def intro_ui?
      Rails.configuration.x.ui.default_layout.to_s.in?(%w[intro dashboard])
    end
  end
end
