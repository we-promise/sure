class AddManualReconciliationToFamilies < ActiveRecord::Migration[8.1]
  def change
    add_column :families, :manual_reconciliation, :boolean, default: false, null: false
  end
end
