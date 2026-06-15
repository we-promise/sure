module CashVault
  class BaseController < ApplicationController
    layout "cash_vault"

    before_action :require_platform_owner!

    private
      def require_platform_owner!
        return if ManualAccountPolicy.platform_owner?(Current.true_user)

        redirect_to root_path, alert: t("cash_vault.shared.not_authorized")
      end
  end
end
