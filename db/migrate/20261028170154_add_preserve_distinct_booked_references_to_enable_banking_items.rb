class AddPreserveDistinctBookedReferencesToEnableBankingItems < ActiveRecord::Migration[8.1]
  def change
    add_column :enable_banking_items, :preserve_distinct_booked_references, :boolean, null: false, default: false
  end
end
