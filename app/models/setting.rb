# Dynamic settings the user can change within the app (helpful for self-hosting)
class Setting < RailsSettings::Base
  class ValidationError < StandardError; end

  cache_prefix { "v1" }

  field :twelve_data_api_key, type: :string, default: ENV["TWELVE_DATA_API_KEY"]
  field :openai_access_token, type: :string, default: ENV["OPENAI_ACCESS_TOKEN"]
  field :openai_uri_base, type: :string, default: ENV["OPENAI_URI_BASE"]
  field :openai_model, type: :string, default: ENV["OPENAI_MODEL"]
  field :brand_fetch_client_id, type: :string, default: ENV["BRAND_FETCH_CLIENT_ID"]

  ONBOARDING_STATES = %w[open closed invite_only].freeze
  DEFAULT_ONBOARDING_STATE = begin
    env_value = ENV["ONBOARDING_STATE"].to_s.presence || "open"
    ONBOARDING_STATES.include?(env_value) ? env_value : "open"
  end

  field :onboarding_state, type: :string, default: DEFAULT_ONBOARDING_STATE
  field :require_invite_for_signup, type: :boolean, default: false
  field :require_email_confirmation, type: :boolean, default: ENV.fetch("REQUIRE_EMAIL_CONFIRMATION", "true") == "true"

  def self.validate_onboarding_state!(state)
    return if ONBOARDING_STATES.include?(state)

    raise ValidationError, I18n.t("settings.hostings.update.invalid_onboarding_state")
  end

  class << self
    alias_method :raw_onboarding_state, :onboarding_state
    alias_method :raw_onboarding_state=, :onboarding_state=

    def onboarding_state
      value = raw_onboarding_state
      return "invite_only" if value.blank? && require_invite_for_signup

      value.presence || DEFAULT_ONBOARDING_STATE
    end

    def onboarding_state=(state)
      validate_onboarding_state!(state)
      self.require_invite_for_signup = state == "invite_only"
      self.raw_onboarding_state = state
    end
  end

  # Validates OpenAI configuration requires model when custom URI base is set
  def self.validate_openai_config!(uri_base: nil, model: nil)
    # Use provided values or current settings
    uri_base_value = uri_base.nil? ? openai_uri_base : uri_base
    model_value = model.nil? ? openai_model : model

    # If custom URI base is set, model must also be set
    if uri_base_value.present? && model_value.blank?
      raise ValidationError, "OpenAI model is required when custom URI base is configured"
    end
  end
end
