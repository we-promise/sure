class AddCostBasisMethodToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :cost_basis_method, :string, null: false, default: "average"
    add_check_constraint :accounts, "cost_basis_method IN ('average', 'fifo')", name: "accounts_cost_basis_method_known"
  end
end
