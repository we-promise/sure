class Settings::HostingsController < ApplicationController
  layout "settings"

  guard_feature unless: -> { self_hosted? }

  before_action :ensure_admin, only: [ :update, :clear_cache ]

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

    if hosting_params.key?(:brand_fetch_client_id)
      Setting.brand_fetch_client_id = hosting_params[:brand_fetch_client_id]
    end

    if hosting_params.key?(:brand_fetch_high_res_logos)
      Setting.brand_fetch_high_res_logos = hosting_params[:brand_fetch_high_res_logos] == "1"
    end

    if hosting_params.key?(:twelve_data_api_key)
      Setting.twelve_data_api_key = hosting_params[:twelve_data_api_key]
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

    redirect_to settings_hosting_path, notice: t(".success")
  rescue Setting::ValidationError => error
    flash.now[:alert] = error.message
    render :show, status: :unprocessable_entity
  end

  def clear_cache
    DataCacheClearJob.perform_later(Current.family)
    redirect_to settings_hosting_path, notice: t(".cache_cleared")
  end

  private
    def hosting_params
      params.require(:setting).permit(:onboarding_state, :require_email_confirmation, :brand_fetch_client_id, :brand_fetch_high_res_logos, :twelve_data_api_key, :openai_access_token, :openai_uri_base, :openai_model, :openai_json_mode, :exchange_rate_provider, :securities_provider, :syncs_include_pending, :auto_sync_enabled, :auto_sync_time)
    end

    def ensure_admin
      redirect_to settings_hosting_path, alert: t(".not_authorized") unless Current.user.admin?
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
