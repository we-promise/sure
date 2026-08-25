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

    if @api_key.save
      flash[:notice] = t(".success")
      redirect_to settings_api_key_path(@api_key, newly_created: true)
    else
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    @api_key.revoke!
    flash[:notice] = t(".revoked_successfully")
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed
    flash[:alert] = t(".revoke_failed")
  ensure
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
