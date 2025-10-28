class AddAccountProviderToHoldings < ActiveRecord::Migration[7.2]
  def change
    add_reference :holdings, :account_provider, null: true, foreign_key: true, type: :uuid, index: true
  end
end
