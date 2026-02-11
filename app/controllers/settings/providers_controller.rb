class Settings::ProvidersController < ApplicationController
  layout "settings"

  before_action :ensure_admin, only: [ :show, :update ]

  def show
    @breadcrumbs = [
      [ "Home", root_path ],
      [ "Sync Providers", nil ]
    ]

    prepare_show_context
  rescue ActiveRecord::Encryption::Errors::Configuration => e
    Rails.logger.error("Active Record Encryption not configured: #{e.message}")
    @encryption_error = true
  end

  def update
    # Build index of valid configurable fields with their metadata
    Provider::Factory.ensure_adapters_loaded
    valid_fields = {}
    Provider::ConfigurationRegistry.all.each do |config|
      config.fields.each do |field|
        valid_fields[field.setting_key.to_s] = field
      end
    end

    updated_fields = []

    # Perform all updates within a transaction for consistency
    Setting.transaction do
      provider_params.each do |param_key, param_value|
        # Only process keys that exist in the configuration registry
        field = valid_fields[param_key.to_s]
        next unless field

        # Clean the value and convert blank/empty strings to nil
        value = param_value.to_s.strip
        value = nil if value.empty?

        # For secret fields only, skip placeholder values to prevent accidental overwrite
        if field.secret && value == "********"
          next
        end

        key_str = field.setting_key.to_s

        # Check if the setting is a declared field in setting.rb
        # Use method_defined? to check if the setter actually exists on the singleton class,
        # not just respond_to? which returns true for dynamic fields due to respond_to_missing?
        if Setting.singleton_class.method_defined?("#{key_str}=")
          # If it's a declared field (e.g., openai_model), set it directly.
          # This is safe and uses the proper setter.
          Setting.public_send("#{key_str}=", value)
        else
          # If it's a dynamic field, set it as an individual entry
          # Each field is stored independently, preventing race conditions
          Setting[key_str] = value
        end

        updated_fields << param_key
      end
    end

    if updated_fields.any?
      # Reload provider configurations if needed
      reload_provider_configs(updated_fields)

      redirect_to settings_providers_path, notice: "Provider settings updated successfully"
    else
      redirect_to settings_providers_path, notice: "No changes were made"
    end
  rescue => error
    Rails.logger.error("Failed to update provider settings: #{error.message}")
    flash.now[:alert] = "Failed to update provider settings: #{error.message}"
    prepare_show_context
    render :show, status: :unprocessable_entity
  end

  private
    def provider_params
      # Dynamically permit all provider configuration fields
      Provider::Factory.ensure_adapters_loaded
      permitted_fields = []

      Provider::ConfigurationRegistry.all.each do |config|
        config.fields.each do |field|
          permitted_fields << field.setting_key
        end
      end

      params.require(:setting).permit(*permitted_fields)
    end

    def ensure_admin
      redirect_to settings_providers_path, alert: "Not authorized" unless Current.user.admin?
    end

    # Reload provider configurations after settings update
    def reload_provider_configs(updated_fields)
      # Build a set of provider keys that had fields updated
      updated_provider_keys = Set.new

      # Look up the provider key directly from the configuration registry
      updated_fields.each do |field_key|
        Provider::ConfigurationRegistry.all.each do |config|
          field = config.fields.find { |f| f.setting_key.to_s == field_key.to_s }
          if field
            updated_provider_keys.add(field.provider_key)
            break
          end
        end
      end

      # Reload configuration for each updated provider
      updated_provider_keys.each do |provider_key|
        adapter_class = Provider::ConfigurationRegistry.get_adapter_class(provider_key)
        adapter_class&.reload_configuration
      end
    end

    # Prepares instance vars needed by the show view and partials
    def prepare_show_context
      # Load all provider configurations (exclude SimpleFin and Lunchflow, which have their own family-specific panels below)
      Provider::Factory.ensure_adapters_loaded
      @provider_configurations = Provider::ConfigurationRegistry.all.reject do |config|
        config.provider_key.to_s.casecmp("simplefin").zero? || config.provider_key.to_s.casecmp("lunchflow").zero? || \
        config.provider_key.to_s.casecmp("enable_banking").zero? || \
        config.provider_key.to_s.casecmp("coinstats").zero? || \
        config.provider_key.to_s.casecmp("mercury").zero? || \
        config.provider_key.to_s.casecmp("coinbase").zero? || \
        config.provider_key.to_s.casecmp("snaptrade").zero? || \
        config.provider_key.to_s.casecmp("indexa_capital").zero?
      end

      # Providers page only needs to know whether any SimpleFin/Lunchflow connections exist with valid credentials
      @simplefin_items = Current.family.simplefin_items.where.not(access_url: [ nil, "" ]).ordered.select(:id)
      @lunchflow_items = Current.family.lunchflow_items.where.not(api_key: [ nil, "" ]).ordered.select(:id)
      @enable_banking_items = Current.family.enable_banking_items.ordered # Enable Banking panel needs session info for status display
      @coinstats_items = Current.family.coinstats_items.ordered # CoinStats panel needs account info for status display
      @mercury_items = Current.family.mercury_items.ordered.select(:id)
      @coinbase_items = Current.family.coinbase_items.ordered # Coinbase panel needs name and sync info for status display
      @snaptrade_items = Current.family.snaptrade_items.includes(:snaptrade_accounts).ordered
      @indexa_capital_items = Current.family.indexa_capital_items.ordered.select(:id)
    end
end
