class SaxoItemsController < ApplicationController
  before_action :require_preview_features!
  before_action :require_admin!
  before_action :set_saxo_item, only: %i[show reconnect sync link_account destroy]

  def new
  end

  def create
    begin_authorization
  end

  def reconnect
    begin_authorization(@saxo_item)
  end

  def callback
    attempt = SaxoAuthorization.consume!(state: params[:state], user: Current.user)
    if params[:error].present? || params[:code].blank?
      raise Provider::Saxo::AuthenticationError, "Saxo authorization was declined"
    end

    tokens = Provider::Saxo.exchange(
      grant_type: "authorization_code",
      code: params[:code],
      redirect_uri: attempt.redirect_uri
    )
    item = if attempt.saxo_item_id
      Current.family.saxo_items.active.find(attempt.saxo_item_id)
    else
      Current.family.saxo_items.create!
    end
    item.with_lock do
      item.update!(
        **tokens,
        application_key_digest: attempt.application_key_digest,
        redirect_uri: attempt.redirect_uri,
        status: :good
      )
    end
    item.sync_later
    redirect_to saxo_item_path(item), notice: t("saxo.connected")
  rescue Provider::Saxo::Error => error
    DebugLogEntry.capture(
      category: "provider_auth_error", level: "error", message: "Saxo authorization failed",
      source: self.class.name, provider_key: "saxo", family: Current.family, user: Current.user,
      metadata: error.diagnostic.presence || { stage: "callback", reason: "authorization_failed" }
    )
    redirect_to settings_providers_path, alert: t("saxo.authorization_failed")
  rescue ActiveRecord::RecordNotFound
    DebugLogEntry.capture(
      category: "provider_auth_error", level: "error", message: "Saxo authorization failed",
      source: self.class.name, provider_key: "saxo", family: Current.family, user: Current.user,
      metadata: { stage: "callback", reason: "authorization_not_found" }
    )
    redirect_to settings_providers_path, alert: t("saxo.authorization_failed")
  end

  def show
    @provider_accounts = @saxo_item.saxo_accounts.includes(:account_provider, :account)
    @visible_account_ids = @saxo_item.accounts.accessible_by(Current.user).pluck(:id).to_set
    @manual_accounts = Current.family.accounts.visible_manual.writable_by(Current.user).where(accountable_type: "Investment")
  end

  def link_account
    provider_account = @saxo_item.saxo_accounts.find(params[:saxo_account_id])
    target = if params[:account_id].present?
      Current.family.accounts.visible_manual.writable_by(Current.user).find(params[:account_id])
    end
    provider_account.link!(target)
    @saxo_item.sync_later
    redirect_to saxo_item_path(@saxo_item), notice: t("saxo.account_linked")
  rescue ArgumentError, ActiveRecord::RecordInvalid
    redirect_to saxo_item_path(@saxo_item), alert: t("saxo.invalid_account")
  end

  def sync
    @saxo_item.sync_later(window_start_date: params[:full_history] == "1" ? @saxo_item.sync_start_date : nil)
    redirect_to saxo_item_path(@saxo_item), notice: t("saxo.sync_started")
  end

  def destroy
    @saxo_item.disconnect!
    redirect_to settings_providers_path, notice: t("saxo.disconnected")
  end

  private
    def set_saxo_item
      @saxo_item = Current.family.saxo_items.active.find(params[:id])
    end

    def begin_authorization(item = nil)
      redirect_uri = callback_saxo_items_url
      state = SaxoAuthorization.begin!(user: Current.user, item: item, redirect_uri: redirect_uri)
      raise Provider::Saxo::AuthenticationError, "Saxo application is not configured" unless Provider::Saxo.configured?
      query = URI.encode_www_form(
        response_type: "code",
        client_id: Setting.saxo_app_key,
        redirect_uri: redirect_uri,
        state: state
      )
      redirect_to "https://live.logonvalidation.net/authorize?#{query}", allow_other_host: true
    rescue Provider::Saxo::Error
      redirect_to settings_providers_path, alert: t("saxo.configuration_required")
    end
end
