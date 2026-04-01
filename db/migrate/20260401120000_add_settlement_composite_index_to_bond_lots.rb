class AddSettlementCompositeIndexToBondLots < ActiveRecord::Migration[7.2]
  def change
    add_index :bond_lots,
              %i[auto_close_on_maturity maturity_date closed_on],
              name: "index_bond_lots_on_settlement_eligibility"
  end
end
