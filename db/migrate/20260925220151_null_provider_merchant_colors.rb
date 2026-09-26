# ProviderMerchant does not support color. merchants.color is a legacy column from
# when every merchant was family-owned (it was `null: false` with a default); the
# migration that introduced the shared ProviderMerchant type made it nullable and
# dropped the default, and nothing since has set it for that type. FamilyMerchant
# is the only type that uses it, so its rows are left alone.
#
# The model now discards any color written to a ProviderMerchant, so this only
# tidies rows that predate that.
class NullProviderMerchantColors < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE merchants
      SET color = NULL
      WHERE type = 'ProviderMerchant'
        AND color IS NOT NULL
    SQL
  end

  # A ProviderMerchant has no color to put back.
  def down
  end
end
