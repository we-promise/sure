class AddOwnerToPlaidItems < ActiveRecord::Migration[8.1]
  def change
    # Nullable and not backfilled on purpose: an item with no owner is
    # manageable by admins only, which is exactly the behaviour every existing
    # connection has today. Ownership is stamped going forward, and
    # ProviderItemOwnable#assign_default_owner fills in a sensible default the
    # next time an older item is saved.
    add_reference :plaid_items, :owner, type: :uuid, null: true, index: true
    add_foreign_key :plaid_items, :users, column: :owner_id, on_delete: :nullify
  end
end
