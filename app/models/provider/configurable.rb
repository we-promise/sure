# Module for providers to declare their configuration requirements
#
# Providers can declare their own configuration fields without needing to modify
# the Setting model. Settings are stored dynamically as individual entries using
# RailsSettings::Base's bracket-style access (Setting[:key] = value).
#
# Configuration fields are automatically registered and displayed in the UI at
# /settings/providers. The system checks Setting storage first, then ENV variables,
# then falls back to defaults.
#
# Example usage in an adapter:
#   class Provider::PlaidAdapter < Provider::Base
#     include Provider::Configurable
#
#     configure do
#       description <<~DESC
#         Setup instructions:
#         1. Visit [Plaid Dashboard](https://dashboard.plaid.com) to get your API credentials
#         2. Configure your Client ID and Secret Key below
#       DESC
#
#       field :client_id,
#             label: "Client ID",
#             required: true,
#             env_key: "PLAID_CLIENT_ID",
#             description: "Your Plaid Client ID from the dashboard"
#
#       field :secret,
#             label: "Secret Key",
#             required: true,
#             secret: true,
#             env_key: "PLAID_SECRET",
#             description: "Your Plaid Secret key"
#
#       field :environment,
#             label: "Environment",
#             required: false,
#             env_key: "PLAID_ENV",
#             default: "sandbox",
#             description: "Plaid environment: sandbox, development, or production"
#     end
#   end
#
# The provider_key is automatically derived from the class name:
#   Provider::PlaidAdapter -> "plaid"
#   Provider::SimplefinAdapter -> "simplefin"
#
# Fields are stored with keys like "plaid_client_id", "plaid_secret", etc.
# Access values via: configuration.get_value(:client_id) or field.value
module Provider::Configurable
  extend ActiveSupport::Concern

  class_methods do
    # Define configuration for this provider
    def configure(&block)
      @configuration = Configuration.new(provider_key)
      @configuration.instance_eval(&block)
      Provider::ConfigurationRegistry.register(provider_key, @configuration, self)
    end

    # Get the configuration for this provider
    def configuration
      @configuration || Provider::ConfigurationRegistry.get(provider_key)
    end

    # Get the provider key (derived from class name)
    # Example: Provider::PlaidAdapter -> "plaid"
    def provider_key
      name.demodulize.gsub(/Adapter$/, "").underscore
    end

    # Get a configuration value
    def config_value(field_name)
      configuration&.get_value(field_name)
    end

    # Check if provider is configured (all required fields present)
    def configured?
      configuration&.configured? || false
    end

    # Reload provider-specific configuration (override in subclasses if needed)
    # This is called after settings are updated in the UI
    # Example: reload Rails.application.config values, reinitialize API clients, etc.
    def reload_configuration
      # Default implementation does nothing
      # Override in provider adapters that need to reload configuration
    end
  end

  # Instance methods
  def provider_key
    self.class.provider_key
  end

  def configuration
    self.class.configuration
  end

  def config_value(field_name)
    self.class.config_value(field_name)
  end

  def configured?
    self.class.configured?
  end

  # Configuration DSL
  class Configuration
    attr_reader :provider_key, :fields, :provider_description

    def initialize(provider_key)
      @provider_key = provider_key
      @fields = []
      @provider_description = nil
      @configured_check = nil
    end

    # Set the provider-level description (markdown supported)
    # @param text [String] The description text for this provider
    def description(text)
      @provider_description = text
    end

    # Define a custom check for whether this provider is configured
    # @param block [Proc] A block that returns true if the provider is configured
    # Example:
    #   configured_check { get_value(:client_id).present? && get_value(:secret).present? }
    def configured_check(&block)
      @configured_check = block
    end

    # Define a configuration field
    # @param name [Symbol] The field name
    # @param label [String] Human-readable label
    # @param required [Boolean] Whether this field is required
    # @param secret [Boolean] Whether this field contains sensitive data (will be masked in UI)
    # @param env_key [String] The ENV variable key for this field
    # @param default [String] Default value if none provided
    # @param description [String] Optional help text
    def field(name, label:, required: false, secret: false, env_key: nil, default: nil, description: nil)
      @fields << ConfigField.new(
        name: name,
        label: label,
        required: required,
        secret: secret,
        env_key: env_key,
        default: default,
        description: description,
        provider_key: @provider_key
      )
    end

    # Get value for a field (checks Setting, then ENV, then default)
    def get_value(field_name)
      field = fields.find { |f| f.name == field_name }
      return nil unless field

      field.value
    end

    # Check if provider is properly configured
    # Uses custom configured_check if defined, otherwise checks required fields
    def configured?
      if @configured_check
        instance_eval(&@configured_check)
      else
        required_fields = fields.select(&:required)
        if required_fields.any?
          required_fields.all? { |f| f.value.present? }
        else
          # If no required fields, provider is not considered configured
          # unless it defines a custom configured_check
          false
        end
      end
    end

    # Get all field values as a hash
    def to_h
      fields.each_with_object({}) do |field, hash|
        hash[field.name] = field.value
      end
    end
  end

  # Represents a single configuration field
  class ConfigField
    attr_reader :name, :label, :required, :secret, :env_key, :default, :description, :provider_key

    def initialize(name:, label:, required:, secret:, env_key:, default:, description:, provider_key:)
      @name = name
      @label = label
      @required = required
      @secret = secret
      @env_key = env_key
      @default = default
      @description = description
      @provider_key = provider_key
    end

    # Get the setting key for this field
    # Example: plaid_client_id
    def setting_key
      "#{provider_key}_#{name}".to_sym
    end

    # Get the value for this field (Setting -> ENV -> default)
    def value
      # First try Setting using dynamic bracket-style access
      # Each field is stored as an individual entry without explicit field declarations
      setting_value = Setting[setting_key]
      return normalize_value(setting_value) if setting_value.present?

      # Then try ENV if env_key is specified
      if env_key.present?
        env_value = ENV[env_key]
        return normalize_value(env_value) if env_value.present?
      end

      # Finally return default
      normalize_value(default)
    end

    # Check if this field has a value
    def present?
      value.present?
    end

    # Validate the current value
    # Returns true if valid, false otherwise
    def valid?
      validate.empty?
    end

    # Get validation errors for the current value
    # Returns an array of error messages
    def validate
      errors = []
      current_value = value

      # Required validation
      if required && current_value.blank?
        errors << "#{label} is required"
      end

      # Additional validations can be added here in the future:
      # - Format validation (regex)
      # - Length validation
      # - Enum validation
      # - Custom validation blocks

      errors
    end

    # Validate and raise an error if invalid
    def validate!
      errors = validate
      raise ArgumentError, "Invalid configuration for #{setting_key}: #{errors.join(", ")}" if errors.any?
      true
    end

    private
      # Normalize value by stripping whitespace and converting empty strings to nil
      def normalize_value(val)
        return nil if val.nil?
        normalized = val.to_s.strip
        normalized.empty? ? nil : normalized
      end
  end
end

# Registry to store all provider configurations
module Provider::ConfigurationRegistry
  class << self
    def register(provider_key, configuration, adapter_class = nil)
      registry[provider_key] = configuration
      adapter_registry[provider_key] = adapter_class if adapter_class
    end

    def get(provider_key)
      registry[provider_key]
    end

    def all
      registry.values
    end

    def providers
      registry.keys
    end

    # Get the adapter class for a provider key
    def get_adapter_class(provider_key)
      adapter_registry[provider_key]
    end

    private
      def registry
        @registry ||= {}
      end

      def adapter_registry
        @adapter_registry ||= {}
      end
  end
end
