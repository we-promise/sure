class AddInvestmentContributionTransferSettingToFamilies < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :treat_investment_contributions_as_transfers, :boolean, null: false, default: false
  end
end
