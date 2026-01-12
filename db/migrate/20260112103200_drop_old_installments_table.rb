class DropOldInstallmentsTable < ActiveRecord::Migration[7.2]
  def up
    if table_exists?(:installments)
      # Remove foreign key from transactions first
      if foreign_key_exists?(:transactions, :installments)
        remove_foreign_key :transactions, :installments
      end

      # Remove the installment_id column from transactions
      if column_exists?(:transactions, :installment_id)
        remove_column :transactions, :installment_id
      end

      # Now we can drop the installments table
      drop_table :installments
    end
  end

  def down
    # Cannot recreate the old table structure as we don't know what it was
    # This is a one-way migration
  end
end
