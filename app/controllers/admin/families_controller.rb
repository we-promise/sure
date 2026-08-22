# frozen_string_literal: true

module Admin
  class FamiliesController < Admin::BaseController
    def destroy
      family = Family.find(params[:id])
      authorize family

      if family.users.exists?
        redirect_to admin_users_path, alert: t(".family_has_users")
        return
      end

      if family.has_active_subscription?
        redirect_to admin_users_path, alert: t(".family_has_active_subscription")
        return
      end

      family.destroy!
      redirect_to admin_users_path, notice: t(".success")
    end
  end
end
