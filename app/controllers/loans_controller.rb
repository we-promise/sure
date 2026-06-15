class LoansController < ApplicationController
  include AccountableResource

  before_action :ensure_hidden_entry_allowed!, only: :new
  before_action :ensure_hidden_entry_unlocked!, only: :create

  permitted_accountable_attributes(
    :id, :subtype, :rate_type, :interest_rate, :term_months, :initial_balance
  )

  def new
    session[:hidden_loan_entry_unlocked] = true
    @account = Current.family.accounts.build(
      balance: 0,
      currency: Current.family.currency,
      accountable: Loan.new(initial_balance: 0)
    )
  end

  def create
    super
  ensure
    session.delete(:hidden_loan_entry_unlocked) if performed? && response.redirect?
  end

  private
    def ensure_hidden_entry_allowed!
      return if params[:hidden_entry].present? && ManualAccountPolicy.platform_owner?(Current.user)

      redirect_to accounts_path, alert: t("accounts.not_authorized")
    end

    def ensure_hidden_entry_unlocked!
      return if ManualAccountPolicy.platform_owner?(Current.user) && session[:hidden_loan_entry_unlocked] == true

      redirect_to accounts_path, alert: t("accounts.not_authorized")
    end
end
