class InviteCodesController < ApplicationController
  before_action :ensure_self_hosted
  before_action :ensure_admin

  def index
    @invite_codes = InviteCode.all
  end

  def create
    InviteCode.generate!
    redirect_back_or_to invite_codes_path, notice: "Code generated"
  end

  def destroy
    code = InviteCode.find(params[:id])
    code.destroy
    redirect_back_or_to invite_codes_path, notice: "Code deleted"
  end

  private

    def ensure_self_hosted
      redirect_to root_path unless self_hosted?
    end

    def ensure_admin
      redirect_to root_path, alert: "Not authorized" unless Current.user.admin?
    end
end
