class ValuablesController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes :id

  def create
    super
  rescue ActiveRecord::RecordInvalid => error
    @error_message = error.record.errors.full_messages.to_sentence
    @account ||= Current.family.accounts.new(account_params.except(:return_to))
    render :new, status: :unprocessable_entity
  end

  def refresh_valuation
    account = Current.user.accessible_accounts.find(params[:id])
    raise ActiveRecord::RecordNotFound unless account.valuable?
    return unless require_account_permission!(account)

    ValuableValuation.new(account:, reconciliation_name: t("valuables.activity.valuation_refreshed")).refresh!
    redirect_to account_path(account), notice: t(".success")
  rescue ValuableValuation::Error, ActiveRecord::RecordInvalid => error
    DebugLogEntry.capture(
      category: "valuable_valuation", level: "error", message: error.message,
      source: "ValuablesController#refresh_valuation", family: account.family,
      account: account, metadata: { account_id: account.id }
    )
    redirect_to account_path(account), alert: t(".failure")
  end

  private
    def set_manageable_account
      super
      raise ActiveRecord::RecordNotFound unless @account.valuable?
    end

    def account_params
      attrs = super.except(:balance, :opening_balance_date, :subtype)
      attrs[:accountable_type] = "Valuable"
      attrs[:balance] = 0 if action_name == "create"
      attrs
    end
end
