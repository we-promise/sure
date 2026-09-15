class AddRequestedConsentValidUntilIndexToEnableBankingItems < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    # Supports the with_stale_psu_ip scope's new middle branch: items that never
    # completed authorization (session_expires_at IS NULL) but do have an
    # ASPSP-accepted consent duration on record, which takes priority over the
    # updated_at fallback.
    add_index :enable_banking_items, :requested_consent_valid_until,
      where: "last_psu_ip IS NOT NULL AND session_expires_at IS NULL",
      name: "index_enable_banking_items_on_requested_consent_for_stale_ip",
      algorithm: :concurrently
  end
end
