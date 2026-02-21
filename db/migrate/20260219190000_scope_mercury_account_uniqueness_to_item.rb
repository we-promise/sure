# frozen_string_literal: true

class ScopeMercuryAccountUniquenessToItem < ActiveRecord::Migration[7.2]
  def up
    # Allow the same Mercury account_id to be linked by different families (different mercury_items).
    # Uniqueness is scoped per mercury_item, mirroring simplefin_accounts.
    remove_index :mercury_accounts, name: "index_mercury_accounts_on_account_id", if_exists: true
    unless index_exists?(:mercury_accounts, [ :mercury_item_id, :account_id ], unique: true, name: "index_mercury_accounts_on_item_and_account_id")
      add_index :mercury_accounts,
                [ :mercury_item_id, :account_id ],
                unique: true,
                name: "index_mercury_accounts_on_item_and_account_id"
    end
  end

  def down
    remove_index :mercury_accounts, name: "index_mercury_accounts_on_item_and_account_id", if_exists: true
    unless index_exists?(:mercury_accounts, :account_id, name: "index_mercury_accounts_on_account_id")
      add_index :mercury_accounts, :account_id, name: "index_mercury_accounts_on_account_id", unique: true
    end
  end
end
