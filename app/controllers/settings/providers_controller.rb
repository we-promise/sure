class Settings::ProvidersController < ApplicationController
  layout -> { turbo_frame_request? ? "turbo_rails/frame" : "settings" }

  before_action :ensure_admin, only: [ :show, :update, :sync_all, :sync, :connect_form ]

  def show
    @breadcrumbs = [
      [ "Home", root_path ],
      [ "Bank sync", nil ]
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

  def sync_all
    family = Current.family
    now = Time.current

    updated_count = Family
      .where(id: family.id)
      .where("last_sync_all_attempted_at IS NULL OR last_sync_all_attempted_at <= ?", 30.seconds.ago)
      .update_all(last_sync_all_attempted_at: now, updated_at: now)

    if updated_count.zero?
      return redirect_to settings_providers_path, notice: t("settings.providers.sync_all_recently")
    end

    SyncAllProvidersJob.perform_later(family.id)
    redirect_to settings_providers_path, notice: t("settings.providers.sync_all_in_progress")
  end

  def sync
    provider_key  = params[:provider_key]
    syncable_type = PANEL_SYNCABLE_TYPES[provider_key]
    return redirect_to settings_providers_path unless syncable_type

    items = syncable_type.constantize.where(family: Current.family).syncable
    scheduled = items.reject(&:syncing?)
    scheduled.each(&:sync_later)

    notice_key = scheduled.any? ? "settings.providers.sync_provider_in_progress" : "settings.providers.sync_provider_no_items"
    redirect_to settings_providers_path, notice: t(notice_key)
  end

  def connect_form
    provider_key = params[:provider_key]

    panel = FAMILY_PANELS.find { |p| p[:key] == provider_key }
    if panel
      @panel_key     = panel[:key]
      @panel_partial = panel[:partial]
      @panel_title   = panel[:title]
      load_provider_items(provider_key)
      return render :connect_form
    end

    Provider::Factory.ensure_adapters_loaded
    config = Provider::ConfigurationRegistry.all.find { |c| c.provider_key.to_s == provider_key }
    if config
      @panel_title           = Provider::Metadata.for(provider_key)[:name] || provider_key.titleize
      @provider_configuration = config
      return render :connect_form
    end

    redirect_to settings_providers_path, alert: t("settings.providers.not_found")
  rescue ActiveRecord::Encryption::Errors::Configuration
    redirect_to settings_providers_path, alert: t("settings.providers.encryption_error.title")
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
      return if Current.user.admin?

      redirect_to root_path, alert: t("settings.providers.not_authorized")
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
      { key: "lunchflow",      title: "Lunch Flow",      turbo_id: "lunchflow",      partial: "lunchflow_panel" },
      { key: "simplefin",      title: "SimpleFIN",       turbo_id: "simplefin",      partial: "simplefin_panel" },
      { key: "enable_banking", title: "Enable Banking",  turbo_id: "enable_banking", partial: "enable_banking_panel" },
      { key: "coinstats",      title: "CoinStats",       turbo_id: "coinstats",      partial: "coinstats_panel" },
      { key: "mercury",        title: "Mercury",         turbo_id: "mercury",        partial: "mercury_panel" },
      { key: "coinbase",       title: "Coinbase",        turbo_id: "coinbase",       partial: "coinbase_panel" },
      { key: "binance",        title: "Binance",         turbo_id: "binance",        partial: "binance_panel" },
      { key: "kraken",         title: "Kraken",          turbo_id: "kraken",         partial: "kraken_panel" },
      { key: "snaptrade",      title: "SnapTrade",       turbo_id: "snaptrade",      partial: "snaptrade_panel", auto_open: "manage" },
      { key: "ibkr",           title: "Interactive Brokers", turbo_id: "ibkr",      partial: "ibkr_panel" },
      { key: "indexa_capital", title: "Indexa Capital",  turbo_id: "indexa_capital", partial: "indexa_capital_panel" },
      { key: "sophtron",       title: "Sophtron",        turbo_id: "sophtron",       partial: "sophtron_panel" }
    ].freeze

    FAMILY_PANEL_KEYS = FAMILY_PANELS.map { |p| p[:key] }.freeze

    # Maps panel key → ActiveRecord model name for sync health queries
    PANEL_SYNCABLE_TYPES = {
      "simplefin"      => "SimplefinItem",
      "lunchflow"      => "LunchflowItem",
      "enable_banking" => "EnableBankingItem",
      "coinstats"      => "CoinstatsItem",
      "mercury"        => "MercuryItem",
      "coinbase"       => "CoinbaseItem",
      "binance"        => "BinanceItem",
      "kraken"         => "KrakenItem",
      "snaptrade"      => "SnaptradeItem",
      "ibkr"           => "IbkrItem",
      "indexa_capital" => "IndexaCapitalItem",
      "sophtron"       => "SophtronItem"
    }.freeze

    def load_provider_items(provider_key)
      case provider_key
      when "simplefin"
        @simplefin_items = Current.family.simplefin_items.ordered
      when "lunchflow"
        @lunchflow_items = Current.family.lunchflow_items.ordered
      when "enable_banking"
        @enable_banking_items = Current.family.enable_banking_items.ordered
      when "coinstats"
        @coinstats_items = Current.family.coinstats_items.ordered
      when "mercury"
        @mercury_items = Current.family.mercury_items.active.ordered.includes(:syncs, :mercury_accounts)
      when "coinbase"
        @coinbase_items = Current.family.coinbase_items.ordered
      when "binance"
        @binance_items = Current.family.binance_items.active.ordered
      when "kraken"
        @kraken_items = Current.family.kraken_items.active.ordered
      when "snaptrade"
        @snaptrade_items = Current.family.snaptrade_items.includes(:snaptrade_accounts).ordered
      when "ibkr"
        @ibkr_items = Current.family.ibkr_items.ordered
      when "indexa_capital"
        @indexa_capital_items = Current.family.indexa_capital_items.ordered
      when "sophtron"
        @sophtron_items = Current.family.sophtron_items.ordered
      end
    end

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
      @mercury_items = Current.family.mercury_items.active.ordered
      @coinbase_items = Current.family.coinbase_items.ordered # Coinbase panel needs name and sync info for status display
      @snaptrade_items = Current.family.snaptrade_items.ordered
      @ibkr_items = Current.family.ibkr_items.ordered.select(:id)
      @indexa_capital_items = Current.family.indexa_capital_items.ordered.select(:id)
      @binance_items = Current.family.binance_items.active.ordered
      @kraken_items = Current.family.kraken_items.active.ordered

      @provider_sync_health = compute_provider_sync_health(family_panel_items)

      entries = build_provider_entries

      @connected        = entries.select { |e| e[:summary][:status] == :ok }
      @needs_attention  = entries.select { |e| [ :warn, :err ].include?(e[:summary][:status]) }
      @available        = entries.select { |e| e[:summary][:status] == :off }

      @health = view_context.provider_health_strip(connected: @connected, needs_attention: @needs_attention)
    end

    # Maps each family panel key to the loaded item collection. Used by
    # compute_provider_sync_health and build_provider_entries to avoid relying
    # on instance_variable_get for control flow.
    def family_panel_items
      {
        "simplefin"      => @simplefin_items,
        "lunchflow"      => @lunchflow_items,
        "enable_banking" => @enable_banking_items,
        "coinstats"      => @coinstats_items,
        "mercury"        => @mercury_items,
        "coinbase"       => @coinbase_items,
        "binance"        => @binance_items,
        "kraken"         => @kraken_items,
        "snaptrade"      => @snaptrade_items,
        "ibkr"           => @ibkr_items,
        "indexa_capital" => @indexa_capital_items,
        "sophtron"       => @sophtron_items
      }
    end

    # Returns a hash mapping provider key → { error:, last_synced_at:, stale: }
    # by querying the latest sync per item for each family panel provider.
    def compute_provider_sync_health(items_map)
      PANEL_SYNCABLE_TYPES.each_with_object({}) do |(key, syncable_type), health|
        ids = items_map[key]&.map(&:id)&.compact
        next if ids.blank?

        health[key] = sync_health_for(syncable_type, ids)
      end
    end

    # Determines error/stale status and last successful sync time for a set of items.
    def sync_health_for(syncable_type, item_ids)
      # Use window function to get the single latest sync per item (same pattern as ProviderConnectionStatus)
      ranked_subq = Sync
        .where(syncable_type: syncable_type, syncable_id: item_ids)
        .select("syncs.*, ROW_NUMBER() OVER (PARTITION BY syncable_id ORDER BY created_at DESC, id DESC) AS sync_rank")

      latest_per_item = Sync.from(ranked_subq, :syncs).where("sync_rank = 1").to_a

      has_error = latest_per_item.any? { |s| s.failed? || s.stale? }

      last_synced = Sync
        .where(syncable_type: syncable_type, syncable_id: item_ids, status: "completed")
        .maximum(:completed_at)

      stale = !has_error && last_synced.present? && last_synced < 24.hours.ago

      { error: has_error, last_synced_at: last_synced, stale: stale }
    end

    # Builds a unified list of provider entries (registry-driven configurations
    # and hardcoded family panels) with pre-computed status, sorted
    # alphabetically by display title. Each entry carries enough data for the
    # view to render either a provider_form or a family panel partial.
    def build_provider_entries
      configuration_entries = @provider_configurations.map do |config|
        meta = Provider::Metadata.for(config.provider_key)
        {
          provider_key: config.provider_key.to_s,
          title: meta[:name] || config.provider_key.to_s.titleize,
          configuration: config,
          maturity: meta[:maturity],
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
          maturity: Provider::Metadata.for(panel[:key])[:maturity],
          summary: view_context.provider_summary(panel[:key])
        }
      end

      (configuration_entries + family_entries).sort_by { |entry| entry[:title].downcase }
    end
end
