# frozen_string_literal: true

class AddUniqueActiveOnchainWalletItemPerFamily < ActiveRecord::Migration[7.2]
  def up
    # Soft-delete older duplicates so the partial unique index can be added.
    execute <<~SQL
      UPDATE onchain_wallet_items
      SET scheduled_for_deletion = TRUE
      WHERE id IN (
        SELECT id FROM (
          SELECT id,
                 ROW_NUMBER() OVER (
                   PARTITION BY family_id
                   ORDER BY created_at DESC, id DESC
                 ) AS rn
          FROM onchain_wallet_items
          WHERE scheduled_for_deletion = FALSE
        ) ranked
        WHERE rn > 1
      )
    SQL

    add_index :onchain_wallet_items, :family_id,
              unique: true,
              where: "scheduled_for_deletion = FALSE",
              name: "index_onchain_wallet_items_on_family_id_active"
  end

  def down
    remove_index :onchain_wallet_items, name: "index_onchain_wallet_items_on_family_id_active"
  end
end
