class AddInvestmentCashflowSupport < ActiveRecord::Migration[7.2]
  # No-op: exclude_from_cashflow was consolidated into the existing 'excluded' toggle
  def change
  end
end
