class EquityGrantsController < ApplicationController
  include InvestmentDocuments

  TAB = "grants".freeze

  before_action :set_writable_account, only: %i[create import upload read_statements]
  before_action :set_grant, only: %i[update destroy]

  def create
    grant = @account.equity_grants.build(grant_params.merge(source: "manual"))

    if grant.save
      redirect_to investment_tab_path(TAB), notice: t(".created")
    else
      redirect_to investment_tab_path(TAB), alert: grant.errors.full_messages.to_sentence
    end
  end

  def update
    if @grant.update(grant_params)
      redirect_to investment_tab_path(TAB), notice: t(".updated")
    else
      redirect_to investment_tab_path(TAB), alert: @grant.errors.full_messages.to_sentence
    end
  end

  def destroy
    @grant.destroy!
    redirect_to investment_tab_path(TAB), notice: t(".deleted")
  end

  def import
    import_csv(kind: "equity_grants", tab: TAB, default_ticker: params[:ticker].presence)
  end

  def upload
    upload_documents(kind: "equity_grants", tab: TAB)
  end

  def read_statements
    read_existing_statements(kind: "equity_grants", tab: TAB)
  end

  def template
    send_data "grant_id,ticker,grant_type,grant_date,total_units,vest_date,units,units_withheld,net_proceeds\n" \
              "GRANT-001,ACME,rsu,2025-03-01,240,2026-03-15,60,25,\n" \
              "GRANT-001,ACME,rsu,2025-03-01,240,2026-06-15,60,,8500.00\n",
              filename: "equity_grants_template.csv", type: "text/csv"
  end

  private
    def set_grant
      @grant = EquityGrant.where(account_id: Current.user.accessible_accounts.select(:id)).find(params[:id])
      @account = @grant.account
      require_account_permission!(@account)
    end

    def grant_params
      params.require(:equity_grant).permit(:grant_identifier, :ticker, :grant_type, :grant_date, :total_units, :notes)
    end
end
