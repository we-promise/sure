# frozen_string_literal: true

class Settings::ApiKeysController < ApplicationController
  layout "settings"

  before_action :set_api_key, only: [ :show, :destroy ]

  def index
    @api_keys = Current.user.api_keys.active.visible.order(created_at: :desc)
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.api_keys"), nil ]
    ]
  end

  def show
    @newly_created = params[:newly_created].present?
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.api_keys"), settings_api_keys_path ],
      [ @api_key.name, nil ]
    ]
  end

  def new
    @api_key = ApiKey.new
  end

  def create
    @plain_key = ApiKey.generate_secure_key
    @api_key = Current.user.api_keys.build(api_key_params)
    @api_key.key = @plain_key

    ActiveRecord::Base.transaction do
      @api_key.save!
      SecurityAuditLog.log_api_key_created!(user: Current.user, api_key: @api_key, request: request)
    end

    flash[:notice] = t(".success")
    redirect_to settings_api_key_path(@api_key, newly_created: true)
  rescue ActiveRecord::RecordInvalid
    render :new, status: :unprocessable_entity
  end

  def destroy
    begin
      @api_key.revoke!
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed
      flash[:alert] = t(".revoke_failed")
      return redirect_to settings_api_keys_path
    end

    begin
      SecurityAuditLog.log_api_key_revoked!(user: Current.user, api_key: @api_key, request: request)
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("[Settings::ApiKeys] Failed to write audit log for revoked key #{@api_key.id}: #{e.message}")
    end

    flash[:notice] = t(".revoked_successfully")
    redirect_to settings_api_keys_path
  end

  private

    # `.visible` excludes the demo monitoring key, so a demo key id 404s here
    # before #destroy can revoke it — this is intentional (see the SECURITY note
    # on ApiKey's `visible` scope).
    def set_api_key
      @api_key = Current.user.api_keys.active.visible.find(params[:id])
    end

    def api_key_params
      permitted_params = params.require(:api_key).permit(:name, :scopes)
      if permitted_params[:scopes].present?
        permitted_params[:scopes] = [ permitted_params[:scopes] ]
      end
      permitted_params
    end
end
