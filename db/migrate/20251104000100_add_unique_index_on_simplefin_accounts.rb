class AddUniqueIndexOnSimplefinAccounts < ActiveRecord::Migration[7.2]
  def up
    # Ensure we only ever have one SimplefinAccount per upstream account_id per SimplefinItem
    # Allow NULL account_id to appear multiple times (partial index for NOT NULL)
    unless index_exists?(:simplefin_accounts, [ :simplefin_item_id, :account_id ], unique: true, name: "idx_unique_sfa_per_item_and_upstream")
      add_index :simplefin_accounts,
                [ :simplefin_item_id, :account_id ],
                unique: true,
                name: "idx_unique_sfa_per_item_and_upstream",
                where: "account_id IS NOT NULL"
    end
  end

  def down
    if index_exists?(:simplefin_accounts, [ :simplefin_item_id, :account_id ], name: "idx_unique_sfa_per_item_and_upstream")
      remove_index :simplefin_accounts, name: "idx_unique_sfa_per_item_and_upstream"
    end
  end
end
