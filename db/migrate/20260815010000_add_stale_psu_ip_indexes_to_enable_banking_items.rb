class AddStalePsuIpIndexesToEnableBankingItems < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    # Support the with_stale_psu_ip scope's two branches without scanning the
    # whole table: items with an expired session, and items that never
    # completed authorization (session_expires_at IS NULL) falling back to
    # updated_at. Both are partial on last_psu_ip IS NOT NULL since the scope
    # always filters on that first.
    add_index :enable_banking_items, :session_expires_at,
      where: "last_psu_ip IS NOT NULL",
      name: "index_enable_banking_items_on_session_expires_at_for_stale_ip",
      algorithm: :concurrently

    add_index :enable_banking_items, :updated_at,
      where: "last_psu_ip IS NOT NULL AND session_expires_at IS NULL",
      name: "index_enable_banking_items_on_updated_at_for_stale_ip",
      algorithm: :concurrently
  end
end
