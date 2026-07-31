# frozen_string_literal: true

module Admin
  class FamiliesController < Admin::BaseController
    def destroy
      family = Family.find(params[:id])

      if family.users.exists?
        redirect_to admin_users_path, alert: t(".family_has_users")
        return
      end

      family.destroy!
      redirect_to admin_users_path, notice: t(".success")
    end
  end
end