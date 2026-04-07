class Settings::HostingsController < ApplicationController
  layout "settings"

  guard_feature unless: -> { self_hosted? }

  before_action :ensure_admin, only: [ :update, :clear_cache, :disconnect_external_assistant, :import_gus_inflation_rates ]
  before_action :ensure_super_admin_for_onboarding, only: :update
  before_action :set_inflation_stats, only: [ :show, :update ]

  def show
    @breadcrumbs = [
      [ "Home", root_path ],
      [ "Self-Hosting", nil ]
    ]

    # Determine which providers are currently selected
    exchange_rate_provider = ENV["EXCHANGE_RATE_PROVIDER"].presence || Setting.exchange_rate_provider
    securities_provider = ENV["SECURITIES_PROVIDER"].presence || Setting.securities_provider

    # Show Twelve Data settings if either provider is set to twelve_data
    @show_twelve_data_settings = exchange_rate_provider == "twelve_data" || securities_provider == "twelve_data"

    # Show Yahoo Finance settings if either provider is set to yahoo_finance
    @show_yahoo_finance_settings = exchange_rate_provider == "yahoo_finance" || securities_provider == "yahoo_finance"

    # Only fetch provider data if we're showing the section
    if @show_twelve_data_settings
      twelve_data_provider = Provider::Registry.get_provider(:twelve_data)
      @twelve_data_usage = twelve_data_provider&.usage
      @plan_restricted_securities = Current.family.securities_with_plan_restrictions(provider: "TwelveData")
    end

    if @show_yahoo_finance_settings
      @yahoo_finance_provider = Provider::Registry.get_provider(:yahoo_finance)
    end
  end

  def update
    if hosting_params.key?(:onboarding_state)
      onboarding_state = hosting_params[:onboarding_state].to_s
      Setting.onboarding_state = onboarding_state
    end

    if hosting_params.key?(:require_email_confirmation)
      Setting.require_email_confirmation = hosting_params[:require_email_confirmation]
    end

    if hosting_params.key?(:invite_only_default_family_id)
      value = hosting_params[:invite_only_default_family_id].presence
      Setting.invite_only_default_family_id = value
    end

    if hosting_params.key?(:brand_fetch_client_id)
      Setting.brand_fetch_client_id = hosting_params[:brand_fetch_client_id]
    end

    if hosting_params.key?(:brand_fetch_high_res_logos)
      Setting.brand_fetch_high_res_logos = hosting_params[:brand_fetch_high_res_logos] == "1"
    end

    if hosting_params.key?(:twelve_data_api_key)
      Setting.twelve_data_api_key = hosting_params[:twelve_data_api_key]
    end

    if hosting_params[:clear_gus_sdp_api_key] == "1" && ENV["GUS_SDP_API_KEY"].blank?
      Setting.gus_sdp_api_key = nil
    elsif hosting_params.key?(:gus_sdp_api_key) && ENV["GUS_SDP_API_KEY"].blank?
      key_value = hosting_params[:gus_sdp_api_key].to_s.strip
      # Ignore blanks and redaction placeholders to prevent accidental overwrite
      Setting.gus_sdp_api_key = key_value unless key_value.blank? || key_value == "********"
    end

    if hosting_params.key?(:gus_inflation_import_enabled) && ENV["GUS_INFLATION_IMPORT_ENABLED"].blank?
      Setting.gus_inflation_import_enabled = hosting_params[:gus_inflation_import_enabled] == "1"
    end

    if hosting_params.key?(:us_bls_cpi_base_url) && ENV["US_BLS_CPI_BASE_URL"].blank?
      Setting.us_bls_cpi_base_url = hosting_params[:us_bls_cpi_base_url].to_s.strip.presence
    end

    if hosting_params.key?(:us_bls_cpi_series_id) && ENV["US_BLS_CPI_SERIES_ID"].blank?
      Setting.us_bls_cpi_series_id = hosting_params[:us_bls_cpi_series_id].to_s.strip.presence
    end

    if hosting_params.key?(:es_ine_cpi_base_url) && ENV["ES_INE_CPI_BASE_URL"].blank?
      Setting.es_ine_cpi_base_url = hosting_params[:es_ine_cpi_base_url].to_s.strip.presence
    end

    if hosting_params.key?(:es_ine_cpi_series_id) && ENV["ES_INE_CPI_SERIES_ID"].blank?
      Setting.es_ine_cpi_series_id = hosting_params[:es_ine_cpi_series_id].to_s.strip.presence
    end

    if hosting_params.key?(:exchange_rate_provider)
      Setting.exchange_rate_provider = hosting_params[:exchange_rate_provider]
    end

    if hosting_params.key?(:securities_provider)
      Setting.securities_provider = hosting_params[:securities_provider]
    end

    if hosting_params.key?(:syncs_include_pending)
      Setting.syncs_include_pending = hosting_params[:syncs_include_pending] == "1"
    end

    sync_settings_changed = false

    if hosting_params.key?(:auto_sync_enabled)
      Setting.auto_sync_enabled = hosting_params[:auto_sync_enabled] == "1"
      sync_settings_changed = true
    end

    if hosting_params.key?(:auto_sync_time)
      time_value = hosting_params[:auto_sync_time]
      unless Setting.valid_auto_sync_time?(time_value)
        flash[:alert] = t(".invalid_sync_time")
        return redirect_to settings_hosting_path
      end

      Setting.auto_sync_time = time_value
      Setting.auto_sync_timezone = current_user_timezone
      sync_settings_changed = true
    end

    if sync_settings_changed
      sync_auto_sync_scheduler!
    end

    if hosting_params.key?(:openai_access_token)
      token_param = hosting_params[:openai_access_token].to_s.strip
      # Ignore blanks and redaction placeholders to prevent accidental overwrite
      unless token_param.blank? || token_param == "********"
        Setting.openai_access_token = token_param
      end
    end

    # Validate OpenAI configuration before updating
    if hosting_params.key?(:openai_uri_base) || hosting_params.key?(:openai_model)
      Setting.validate_openai_config!(
        uri_base: hosting_params[:openai_uri_base],
        model: hosting_params[:openai_model]
      )
    end

    if hosting_params.key?(:openai_uri_base)
      Setting.openai_uri_base = hosting_params[:openai_uri_base]
    end

    if hosting_params.key?(:openai_model)
      Setting.openai_model = hosting_params[:openai_model]
    end

    if hosting_params.key?(:openai_json_mode)
      Setting.openai_json_mode = hosting_params[:openai_json_mode].presence
    end

    if hosting_params.key?(:external_assistant_url)
      Setting.external_assistant_url = hosting_params[:external_assistant_url]
    end

    if hosting_params.key?(:external_assistant_token)
      token_param = hosting_params[:external_assistant_token].to_s.strip
      unless token_param.blank? || token_param == "********"
        Setting.external_assistant_token = token_param
      end
    end

    if hosting_params.key?(:external_assistant_agent_id)
      Setting.external_assistant_agent_id = hosting_params[:external_assistant_agent_id]
    end

    update_assistant_type

    redirect_to settings_hosting_path, notice: t(".success")
  rescue Setting::ValidationError => error
    flash.now[:alert] = error.message
    render :show, status: :unprocessable_entity
  end

  def clear_cache
    DataCacheClearJob.perform_later(Current.family)
    redirect_to settings_hosting_path, notice: t(".cache_cleared")
  end

  def disconnect_external_assistant
    Setting.external_assistant_url = nil
    Setting.external_assistant_token = nil
    Setting.external_assistant_agent_id = nil
    Current.family.update!(assistant_type: "builtin") unless ENV["ASSISTANT_TYPE"].present?
    redirect_to settings_hosting_path, notice: t(".external_assistant_disconnected")
  rescue => e
    Rails.logger.error("[External Assistant] Disconnect failed: #{e.message}")
    redirect_to settings_hosting_path, alert: t("settings.hostings.update.failure")
  end

  def import_gus_inflation_rates
    if Setting.gus_inflation_import_enabled_effective
      return redirect_to settings_hosting_path, alert: t(".manual_import_disabled_when_auto_enabled")
    end

    start_year_param = import_params[:gus_inflation_start_year].presence
    end_year_param = import_params[:gus_inflation_end_year].presence

    start_year = start_year_param.nil? ? (Date.current.year - 20) : Integer(start_year_param, exception: false)
    end_year = end_year_param.nil? ? (Date.current.year - 1) : Integer(end_year_param, exception: false)
    valid_range = 1990..Date.current.year

    unless start_year && end_year && valid_range.cover?(start_year) && valid_range.cover?(end_year) && start_year <= end_year
      return redirect_to settings_hosting_path, alert: t(".invalid_import_range")
    end

    ImportInflationRatesJob.perform_later(
      start_year:,
      end_year:,
      force: true,
      providers: [ "gus_sdp", "us_bls", "es_ine" ]
    )

    redirect_to settings_hosting_path, notice: t(".import_enqueued")
  end

  private
    def hosting_params
      return ActionController::Parameters.new unless params.key?(:setting)
      params.require(:setting).permit(:onboarding_state, :require_email_confirmation, :invite_only_default_family_id, :brand_fetch_client_id, :brand_fetch_high_res_logos, :twelve_data_api_key, :gus_sdp_api_key, :clear_gus_sdp_api_key, :gus_inflation_import_enabled, :us_bls_cpi_base_url, :us_bls_cpi_series_id, :es_ine_cpi_base_url, :es_ine_cpi_series_id, :openai_access_token, :openai_uri_base, :openai_model, :openai_json_mode, :exchange_rate_provider, :securities_provider, :syncs_include_pending, :auto_sync_enabled, :auto_sync_time, :external_assistant_url, :external_assistant_token, :external_assistant_agent_id)
    end

    def import_params
      params.fetch(:setting, ActionController::Parameters.new).permit(:gus_inflation_start_year, :gus_inflation_end_year)
    end

    def update_assistant_type
      return unless params[:family].present? && params[:family][:assistant_type].present?
      return if ENV["ASSISTANT_TYPE"].present?

      assistant_type = params[:family][:assistant_type]
      Current.family.update!(assistant_type: assistant_type) if Family::ASSISTANT_TYPES.include?(assistant_type)
    end

    def set_inflation_stats
      @inflation_provider_stats = {
        "gus_sdp" => provider_stats_for_gus,
        "us_bls" => provider_stats_for("us_bls"),
        "es_ine" => provider_stats_for("es_ine")
      }

      raw_details = Setting.inflation_last_import_details.to_s
      @inflation_last_import_details = raw_details.present? ? JSON.parse(raw_details) : {}
    rescue JSON::ParserError
      @inflation_last_import_details = {}
    end

    def provider_stats_for_gus
      cnt, min_yr, max_yr = GusInflationRate.pick(
        Arel.sql("COUNT(*)"),
        Arel.sql("MIN(year)"),
        Arel.sql("MAX(year)")
      ) || [ 0, nil, nil ]

      { count: cnt.to_i, min_year: min_yr, max_year: max_yr }
    end

    def provider_stats_for(source)
      cnt, min_yr, max_yr = InflationRate.where(source: source).pick(
        Arel.sql("COUNT(*)"),
        Arel.sql("MIN(year)"),
        Arel.sql("MAX(year)")
      ) || [ 0, nil, nil ]

      { count: cnt.to_i, min_year: min_yr, max_year: max_yr }
    end

    def ensure_admin
      redirect_to settings_hosting_path, alert: t(".not_authorized") unless Current.user.admin?
    end

    def ensure_super_admin_for_onboarding
      onboarding_params = %i[onboarding_state invite_only_default_family_id]
      return unless onboarding_params.any? { |p| hosting_params.key?(p) }
      redirect_to settings_hosting_path, alert: t(".not_authorized") unless Current.user.super_admin?
    end

    def sync_auto_sync_scheduler!
      AutoSyncScheduler.sync!
    rescue StandardError => error
      Rails.logger.error("[AutoSyncScheduler] Failed to sync scheduler: #{error.message}")
      Rails.logger.error(error.backtrace.join("\n"))
      flash[:alert] = t(".scheduler_sync_failed")
    end

    def current_user_timezone
      Current.family&.timezone.presence || "UTC"
    end
end
