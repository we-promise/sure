class Settings::ProvidersController < ApplicationController
  layout "settings"

  guard_feature unless: -> { self_hosted? }

  before_action :ensure_admin, only: [ :update ]

  def show
    @breadcrumbs = [
      [ "Home", root_path ],
      [ "Bank Sync Providers", nil ]
    ]

    # Load all provider configurations
    Provider::Factory.ensure_adapters_loaded
    @provider_configurations = Provider::ConfigurationRegistry.all
  end

  def update
    updated_fields = []

    # Dynamically update all provider settings based on permitted params
    provider_params.each do |param_key, param_value|
      setting_key = param_key.to_sym

      # Clean the value
      value = param_value.to_s.strip

      # For secret fields, ignore placeholder values to prevent accidental overwrite
      if value == "********"
        next
      end

      # Set the value using dynamic hash-style access
      # This works without explicit field declarations in Setting model
      Setting[setting_key] = value
      updated_fields << param_key
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

      updated_fields.each do |field|
        # Extract provider key from field name (e.g., "plaid_client_id" -> "plaid")
        provider_key = field.to_s.split("_").first
        updated_provider_keys.add(provider_key)
      end

      # Reload configuration for each updated provider
      updated_provider_keys.each do |provider_key|
        adapter_class = Provider::ConfigurationRegistry.get_adapter_class(provider_key)
        adapter_class&.reload_configuration
      end
    end
end
