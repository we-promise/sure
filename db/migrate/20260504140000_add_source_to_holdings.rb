# Adds a `source` column to holdings to identify provider-sourced snapshots
# independently of the legacy polymorphic `account_provider_id` foreign key.
#
# Background: pre-framework, the only "this holding came from a provider snapshot"
# discriminator was `holdings.account_provider_id IS NOT NULL` (the legacy
# polymorphic AccountProvider FK). After the Plaid framework cutover, new Plaid
# holdings cannot use that FK — `provider_accounts.id` and `account_providers.id`
# live in different tables. The new framework writes `source` instead.
#
# Backfill happens later in MigrateLegacyPlaidToFramework (per-item, transactional)
# for legacy Plaid holdings about to lose their AccountProvider row. Non-Plaid
# legacy providers (Coinbase, SimpleFIN, etc.) keep their AccountProvider rows
# and continue to be identified via account_provider_id; their `source` stays NULL.
class AddSourceToHoldings < ActiveRecord::Migration[7.2]
  def change
    add_column :holdings, :source, :string
  end
end
