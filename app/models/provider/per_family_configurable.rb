# Module for providers to declare per-family configuration requirements
#
# Similar to Provider::Configurable, but for providers where each family needs their own credentials.
# Configuration fields are stored in provider-specific tables (e.g., lunchflow_items) with encryption.
#
# Example usage in an adapter:
#   class Provider::LunchflowAdapter < Provider::Base
#     include Provider::PerFamilyConfigurable
#
#     configure_per_family do
#       description <<~DESC
#         Setup instructions:
#         1. Visit [Lunch Flow](https://www.lunchflow.app) to get your API key
#         2. Enter your API key below to enable Lunch Flow bank data sync
#       DESC
#
#       field :api_key,
#             label: "API Key",
#             type: :text,
#             required: true,
#             secret: true,
#             description: "Your Lunch Flow API key for authentication"
#
#       field :base_url,
#             label: "Base URL",
#             type: :string,
#             required: false,
#             default: "https://lunchflow.app/api/v1",
#             description: "Base URL for Lunch Flow API"
#     end
#
#     def self.build_provider(family:)
#       return nil unless family.present?
#       item = family.lunchflow_items.where.not(api_key: nil).first
#       return nil unless item&.credentials_configured?
#       Provider::Lunchflow.new(item.api_key, base_url: item.effective_base_url)
#     end
#   end
#
# The provider_key is automatically derived from the class name:
#   Provider::LunchflowAdapter -> "lunchflow"
#   Provider::SimplefinAdapter -> "simplefin"
#
# Fields are stored in the provider's item model (e.g., LunchflowItem).
# The corresponding model must include Provider::PerFamilyItem concern.
module Provider::PerFamilyConfigurable
  extend ActiveSupport::Concern

  class_methods do
    # Define per-family configuration for this provider
    def configure_per_family(&block)
      @per_family_configuration = PerFamilyConfiguration.new(provider_key, item_model_name)
      @per_family_configuration.instance_eval(&block)
      Provider::PerFamilyConfigurationRegistry.register(provider_key, @per_family_configuration, self)
    end

    # Get the per-family configuration for this provider
    def per_family_configuration
      @per_family_configuration || Provider::PerFamilyConfigurationRegistry.get(provider_key)
    end

    # Get the provider key (derived from class name)
    # Example: Provider::LunchflowAdapter -> "lunchflow"
    def provider_key
      name.demodulize.gsub(/Adapter$/, "").underscore
    end

    # Get the item model name (e.g., "LunchflowItem")
    def item_model_name
      "#{provider_key.camelize}Item"
    end

    # Get the item model class
    def item_model_class
      item_model_name.constantize
    rescue NameError
      nil
    end

    # Get the items association name (e.g., :lunchflow_items)
    def items_association_name
      "#{provider_key}_items".to_sym
    end
  end

  # Instance methods
  def provider_key
    self.class.provider_key
  end

  def per_family_configuration
    self.class.per_family_configuration
  end

  def item_model_name
    self.class.item_model_name
  end

  def item_model_class
    self.class.item_model_class
  end

  def items_association_name
    self.class.items_association_name
  end

  # Per-family configuration DSL
  class PerFamilyConfiguration
    attr_reader :provider_key, :item_model_name, :fields, :provider_description

    def initialize(provider_key, item_model_name)
      @provider_key = provider_key
      @item_model_name = item_model_name
      @fields = []
      @provider_description = nil
    end

    # Set the provider-level description (markdown supported)
    # @param text [String] The description text for this provider
    def description(text)
      @provider_description = text
    end

    # Define a configuration field that will be stored in the item model
    # @param name [Symbol] The field name (must match column in item model)
    # @param label [String] Human-readable label
    # @param type [Symbol] Field type (:text, :string, :integer, :boolean)
    # @param required [Boolean] Whether this field is required
    # @param secret [Boolean] Whether this field contains sensitive data (will be encrypted)
    # @param default [String, Integer, Boolean] Default value if none provided
    # @param description [String] Optional help text
    # @param placeholder [String] Optional placeholder text for form input
    def field(name, label:, type: :string, required: false, secret: false, default: nil, description: nil, placeholder: nil)
      @fields << PerFamilyConfigField.new(
        name: name,
        label: label,
        type: type,
        required: required,
        secret: secret,
        default: default,
        description: description,
        placeholder: placeholder,
        provider_key: @provider_key
      )
    end

    # Get all fields that should be encrypted
    def secret_fields
      fields.select(&:secret)
    end

    # Get all required fields
    def required_fields
      fields.select(&:required)
    end

    # Generate model validations code
    def model_validations
      required_fields.map do |field|
        "validates :#{field.name}, presence: true"
      end.join("\n  ")
    end

    # Generate model encryption code
    def model_encryptions
      return nil if secret_fields.empty?

      field_list = secret_fields.map { |f| ":#{f.name}" }.join(", ")
      <<~RUBY.strip
        if Rails.application.credentials.active_record_encryption.present?
          encrypts #{field_list}, deterministic: true
        end
      RUBY
    end

    # Generate effective_* helper methods for fields with defaults
    def model_helpers
      fields.select { |f| f.default.present? }.map do |field|
        <<~RUBY.strip
          def effective_#{field.name}
            #{field.name}.presence || "#{field.default}"
          end
        RUBY
      end.join("\n\n  ")
    end
  end

  # Represents a single per-family configuration field
  class PerFamilyConfigField
    attr_reader :name, :label, :type, :required, :secret, :default, :description, :placeholder, :provider_key

    def initialize(name:, label:, type:, required:, secret:, default:, description:, placeholder:, provider_key:)
      @name = name
      @label = label
      @type = type
      @required = required
      @secret = secret
      @default = default
      @description = description
      @placeholder = placeholder
      @provider_key = provider_key
    end

    # Get the input type for this field
    def input_type
      case type
      when :text then secret ? :password : :text
      when :string then secret ? :password : :text
      when :integer then :number
      when :boolean then :checkbox
      else :text
      end
    end

    # Get the migration column type
    def migration_type
      case type
      when :text then "text"
      when :string then "string"
      when :integer then "integer"
      when :boolean then "boolean"
      else "string"
      end
    end
  end
end

# Registry to store all per-family provider configurations
module Provider::PerFamilyConfigurationRegistry
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
