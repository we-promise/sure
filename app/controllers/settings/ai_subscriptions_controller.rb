# frozen_string_literal: true

class Settings::AiSubscriptionsController < ApplicationController
  layout "settings"

  before_action :require_admin!

  def show
    @codex_available = defined?(Provider::Codex) && Provider::Codex.configured?
    @codex_status = Provider::Codex.authentication_status if @codex_available
    @codex_login_id = params[:login_id].presence
    @codex_login_state = Provider::Codex.login_state(@codex_login_id)
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.ai_subscriptions"), nil ]
    ]
  end

  def start_codex_login
    login_id = SecureRandom.uuid
    Provider::Codex.prepare_login(login_id)
    CodexLoginJob.perform_later(login_id)

    redirect_to settings_ai_subscriptions_path(login_id: login_id)
  end

  def sign_out_codex
    if Provider::Codex.perform_logout
      redirect_to settings_ai_subscriptions_path, notice: t("settings.ai_subscriptions.show.codex.signed_out")
    else
      redirect_to settings_ai_subscriptions_path, alert: t("settings.ai_subscriptions.show.codex.sign_out_failed")
    end
  end

  def codex_login_status
    login_id = params[:login_id].to_s
    state = Provider::Codex.login_state(login_id) || { "state" => "missing" }

    render partial: "settings/ai_subscriptions/codex_login_status",
           locals: { login_id: login_id, state: state }
  end
end
