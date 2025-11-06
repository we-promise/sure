class Settings::HostingsController < ApplicationController
  layout "settings"

  guard_feature unless: -> { self_hosted? }

  before_action :ensure_admin, only: [ :update, :clear_cache ]

  def show
    @breadcrumbs = [
      [ "Home", root_path ],
      [ "Self-Hosting", nil ]
    ]
    twelve_data_provider = Provider::Registry.get_provider(:twelve_data)
    @twelve_data_usage = twelve_data_provider&.usage

    @yahoo_finance_provider = Provider::Registry.get_provider(:yahoo_finance)
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

    if hosting_params.key?(:twelve_data_api_key)
      Setting.twelve_data_api_key = hosting_params[:twelve_data_api_key]
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
      params.require(:setting).permit(:onboarding_state, :require_email_confirmation, :brand_fetch_client_id, :twelve_data_api_key, :openai_access_token, :openai_uri_base, :openai_model)
    end

    def ensure_admin
      redirect_to settings_hosting_path, alert: t(".not_authorized") unless Current.user.admin?
    end
end
