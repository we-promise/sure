# frozen_string_literal: true

module Admin
  class InvitationsController < Admin::BaseController
    def destroy
      invitation = Invitation.find(params[:id])
      invitation.destroy!
      redirect_to admin_users_path, notice: t(".success")
    end

    def destroy_all
      family = Family.find(params[:id])
      family.invitations.pending.destroy_all
      redirect_to admin_users_path, notice: t(".success")
    end
  end
end
