class Settings::ProvidersController < ApplicationController
  layout "settings"

  before_action :ensure_admin, only: [ :show, :update ]

  def show
    @breadcrumbs = [
      [ "Home", root_path ],
      [ "Bank Sync Providers", nil ]
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
    Rails.logger.error("Failed to update provider settings: #{error.class} - #{error.message}")
    flash.now[:alert] = "Failed to update provider settings. Please try again."
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

    # Hardcoded family-scoped panels — provider connections are managed through
    # their own models (SimplefinItem, LunchflowItem, etc.) rather than global
    # settings, so they need custom UI per-provider for connection management,
    # status display, and sync actions. The configuration registry excludes
    # them (see prepare_show_context).
    FAMILY_PANELS = [
      { key: "lunchflow",      title: "Lunch Flow",             turbo_id: "lunchflow",      partial: "lunchflow_panel" },
      { key: "simplefin",      title: "SimpleFIN",              turbo_id: "simplefin",      partial: "simplefin_panel" },
      { key: "enable_banking", title: "Enable Banking (beta)",  turbo_id: "enable_banking", partial: "enable_banking_panel" },
      { key: "coinstats",      title: "CoinStats (beta)",       turbo_id: "coinstats",      partial: "coinstats_panel" },
      { key: "mercury",        title: "Mercury (beta)",         turbo_id: "mercury",        partial: "mercury_panel" },
      { key: "coinbase",       title: "Coinbase (beta)",        turbo_id: "coinbase",       partial: "coinbase_panel" },
      { key: "binance",        title: "Binance (beta)",         turbo_id: "binance",        partial: "binance_panel" },
      { key: "snaptrade",      title: "SnapTrade (beta)",       turbo_id: "snaptrade",      partial: "snaptrade_panel", auto_open: "manage" },
      { key: "indexa_capital", title: "Indexa Capital (alpha)", turbo_id: "indexa_capital", partial: "indexa_capital_panel" },
      { key: "sophtron",       title: "Sophtron (alpha)",       turbo_id: "sophtron",       partial: "sophtron_panel" }
    ].freeze

    FAMILY_PANEL_KEYS = FAMILY_PANELS.map { |p| p[:key] }.freeze

    # Prepares instance vars needed by the show view and partials
    def prepare_show_context
      # Load all provider configurations (exclude family-scoped panels, which have their own UI below)
      Provider::Factory.ensure_adapters_loaded
      @provider_configurations = Provider::ConfigurationRegistry.all.reject do |config|
        FAMILY_PANEL_KEYS.any? { |key| config.provider_key.to_s.casecmp(key).zero? }
      end

      # Providers page only needs to know whether any SimpleFin/Lunchflow connections exist with valid credentials
      @simplefin_items = Current.family.simplefin_items.where.not(access_url: [ nil, "" ]).ordered.select(:id)
      @lunchflow_items = Current.family.lunchflow_items.where.not(api_key: [ nil, "" ]).ordered.select(:id)
      @enable_banking_items = Current.family.enable_banking_items.ordered # Enable Banking panel needs session info for status display
      # Providers page only needs to know whether any Sophtron connections exist with valid credentials
      @sophtron_items = Current.family.sophtron_items.where.not(user_id: [ nil, "" ], access_key: [ nil, "" ]).ordered.select(:id)
      @coinstats_items = Current.family.coinstats_items.ordered # CoinStats panel needs account info for status display
      @mercury_items = Current.family.mercury_items.active.ordered.includes(:syncs, :mercury_accounts)
      @coinbase_items = Current.family.coinbase_items.ordered # Coinbase panel needs name and sync info for status display
      @snaptrade_items = Current.family.snaptrade_items.includes(:snaptrade_accounts).ordered
      @indexa_capital_items = Current.family.indexa_capital_items.ordered.select(:id)

      entries = build_provider_entries
      @connected_providers, @available_providers = entries.partition { |entry| entry[:summary][:status] == :ok }
    end

    # Builds a unified list of provider entries (registry-driven configurations
    # and hardcoded family panels) with pre-computed status, sorted
    # alphabetically by display title. Each entry carries enough data for the
    # view to render either a provider_form or a family panel partial.
    def build_provider_entries
      configuration_entries = @provider_configurations.map do |config|
        {
          provider_key: config.provider_key.to_s,
          title: config.provider_key.to_s.titleize,
          configuration: config,
          summary: view_context.provider_summary(config.provider_key)
        }
      end

      family_entries = FAMILY_PANELS.map do |panel|
        {
          provider_key: panel[:key],
          title: panel[:title],
          turbo_id: panel[:turbo_id],
          partial: panel[:partial],
          auto_open_param: panel[:auto_open],
          summary: view_context.provider_summary(panel[:key])
        }
      end

      (configuration_entries + family_entries).sort_by { |entry| entry[:title].downcase }
    end
end
