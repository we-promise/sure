class AddCompositeIndexOnAccountsFamilyStatusType < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    add_index :accounts, [ :family_id, :status, :accountable_type ],
      name: "index_accounts_on_family_id_status_accountable_type",
      algorithm: :concurrently
  end
end
