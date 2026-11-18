class AddProviderEntryReferenceToTransactions < ActiveRecord::Migration[8.1]
  def change
    add_column :transactions, :provider_entry_reference, :string
  end
end
