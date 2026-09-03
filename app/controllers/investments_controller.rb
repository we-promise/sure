class InvestmentsController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes :id, :subtype, :gold_form

  def refresh_gold_valuation
    account = Current.user.accessible_accounts.find(params[:id])
    return unless require_account_permission!(account)

    GoldValuation.new(account:).refresh!
    redirect_back_or_to account_path(account), notice: t("investments.refresh_gold_valuation.success")
  rescue GoldValuation::Error, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => error
    DebugLogEntry.capture(
      category: "gold_valuation",
      level: "error",
      message: error.message,
      source: "InvestmentsController#refresh_gold_valuation",
      family: account&.family,
      metadata: { account_id: account&.id }
    )
    redirect_back_or_to account_path(account), alert: t("investments.refresh_gold_valuation.failure")
  end
end
