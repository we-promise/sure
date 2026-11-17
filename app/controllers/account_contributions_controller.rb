class AccountContributionsController < ApplicationController
  include InvestmentDocuments

  TAB = "contributions".freeze

  before_action :set_writable_account, only: %i[create import upload read_statements]

  def create
    contribution = @account.account_contributions.build(contribution_params.merge(source: "manual", currency: @account.currency))

    if contribution.save
      redirect_to investment_tab_path(TAB), notice: t(".created")
    else
      redirect_to investment_tab_path(TAB), alert: contribution.errors.full_messages.to_sentence
    end
  end

  def destroy
    contribution = AccountContribution.where(account_id: Current.user.accessible_accounts.select(:id)).find(params[:id])
    @account = contribution.account
    return unless require_account_permission!(@account)

    contribution.destroy!
    redirect_to investment_tab_path(TAB), notice: t(".deleted")
  end

  def import
    import_csv(kind: "contributions", tab: TAB)
  end

  def upload
    upload_documents(kind: "contributions", tab: TAB)
  end

  def read_statements
    read_existing_statements(kind: "contributions", tab: TAB)
  end

  def template
    send_data "date,amount,kind,description\n2025-01-15,500.00,contribution,Payroll contribution\n2025-01-15,250.00,employer_contribution,Employer match\n2025-03-01,-1000.00,withdrawal,Withdrawal\n",
              filename: "contributions_template.csv", type: "text/csv"
  end

  private
    def contribution_params
      params.require(:account_contribution).permit(:date, :amount, :kind, :description, :principal_amount, :estimated)
    end
end
