class LoansController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes(
    :id, :subtype, :rate_type, :interest_rate, :term_months, :initial_balance, :start_date,
    :down_payment, :insurance_rate, :insurance_rate_type, :day_count_convention,
    :principal_only_transfers, :financed_account_id,
    { rate_changes: [ :effective_date, :rate ] }
  )

  before_action :require_accessible_financed_account, only: [ :create, :update ]

  private
    # A loan may only be linked to an asset the user can see. The link it
    # already holds is resubmitted untouched on every edit, so it passes even if
    # the asset has since stopped being shared with them.
    def require_accessible_financed_account
      financed_account_id = params.dig(:account, :accountable_attributes, :financed_account_id)
      return if financed_account_id.blank?
      return if financed_account_id == @account&.loan&.financed_account_id

      Current.user.accessible_accounts.visible.where(accountable_type: Loan::FINANCEABLE_TYPES).find(financed_account_id)
    end
end
