class InviteCodesController < ApplicationController
  before_action :ensure_self_hosted
  before_action :ensure_super_admin

  def index
    @invite_codes = InviteCode.all
  end

  def create
    InviteCode.generate!
    redirect_back_or_to invite_codes_path, notice: t(".success")
  end

  def destroy
    code = InviteCode.find(params[:id])
    code.destroy
    redirect_back_or_to invite_codes_path, notice: t(".success")
  end

  private

    def ensure_self_hosted
      redirect_to root_path unless self_hosted?
    end

    def ensure_super_admin
      redirect_to root_path, alert: t("settings.hostings.not_authorized") unless Current.user.super_admin?
    end
end
