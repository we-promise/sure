# Dynamic settings the user can change within the app (helpful for self-hosting)
class Setting < RailsSettings::Base
  class ValidationError < StandardError; end

  cache_prefix { "v1" }

  # Third-party API keys
  field :twelve_data_api_key, type: :string, default: ENV["TWELVE_DATA_API_KEY"]
  field :openai_access_token, type: :string, default: ENV["OPENAI_ACCESS_TOKEN"]
  field :openai_uri_base, type: :string, default: ENV["OPENAI_URI_BASE"]
  field :openai_model, type: :string, default: ENV["OPENAI_MODEL"]
  field :openai_json_mode, type: :string, default: ENV["LLM_JSON_MODE"]
  field :brand_fetch_client_id, type: :string, default: ENV["BRAND_FETCH_CLIENT_ID"]

  # Provider selection
  field :exchange_rate_provider, type: :string, default: ENV.fetch("EXCHANGE_RATE_PROVIDER", "twelve_data")
  field :securities_provider, type: :string, default: ENV.fetch("SECURITIES_PROVIDER", "twelve_data")

  # Sync settings - check both provider env vars for default
  # Only defaults to true if neither provider explicitly disables pending
  SYNCS_INCLUDE_PENDING_DEFAULT = begin
    simplefin = ENV.fetch("SIMPLEFIN_INCLUDE_PENDING", "1") == "1"
    plaid = ENV.fetch("PLAID_INCLUDE_PENDING", "1") == "1"
    simplefin && plaid
  end
  field :syncs_include_pending, type: :boolean, default: SYNCS_INCLUDE_PENDING_DEFAULT

  # Dynamic fields are now stored as individual entries with "dynamic:" prefix
  # This prevents race conditions and ensures each field is independently managed

  # Onboarding and app settings
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

    # Support dynamic field access via bracket notation
    # First checks if it's a declared field, then falls back to individual dynamic entries
    def [](key)
      key_str = key.to_s

      # Check if it's a declared field first
      if respond_to?(key_str)
        public_send(key_str)
      else
        # Fall back to individual dynamic entry lookup
        find_by(var: dynamic_key_name(key_str))&.value
      end
    end

    def []=(key, value)
      key_str = key.to_s

      # If it's a declared field, use the setter
      if respond_to?("#{key_str}=")
        public_send("#{key_str}=", value)
      else
        # Store as individual dynamic entry
        dynamic_key = dynamic_key_name(key_str)
        if value.nil?
          where(var: dynamic_key).destroy_all
          clear_cache
        else
          # Use upsert for atomic insert/update to avoid race conditions
          upsert({ var: dynamic_key, value: value.to_yaml }, unique_by: :var)
          clear_cache
        end
      end
    end

    # Check if a dynamic field exists (useful to distinguish nil value vs missing key)
    def key?(key)
      key_str = key.to_s
      return true if respond_to?(key_str)

      # Check if dynamic entry exists
      where(var: dynamic_key_name(key_str)).exists?
    end

    # Delete a dynamic field
    def delete(key)
      key_str = key.to_s
      return nil if respond_to?(key_str) # Can't delete declared fields

      dynamic_key = dynamic_key_name(key_str)
      value = self[key_str]
      where(var: dynamic_key).destroy_all
      clear_cache
      value
    end

    # List all dynamic field keys (excludes declared fields)
    def dynamic_keys
      where("var LIKE ?", "dynamic:%").pluck(:var).map { |var| var.sub(/^dynamic:/, "") }
    end

    private

      def dynamic_key_name(key_str)
        "dynamic:#{key_str}"
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
