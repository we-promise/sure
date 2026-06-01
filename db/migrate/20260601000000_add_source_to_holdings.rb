class AddSourceToHoldings < ActiveRecord::Migration[8.0]
  def up
    add_column :holdings, :source, :string

    # Backfill: provider holdings (account_provider_id set) → "provider", rest → "calculated"
    execute <<~SQL
      UPDATE holdings SET source = 'provider' WHERE account_provider_id IS NOT NULL;
      UPDATE holdings SET source = 'calculated' WHERE account_provider_id IS NULL;
    SQL

    change_column_null :holdings, :source, false, "calculated"
    change_column_default :holdings, :source, "calculated"

    add_index :holdings, :source
  end

  def down
    remove_index :holdings, :source
    remove_column :holdings, :source
  end
end
