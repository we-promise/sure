# The Plaid holdings processor used to date each row by its own
# `institution_price_as_of`, or today when that was missing or unreadable. It
# now writes every holding of a sync on one snapshot date: the newest price
# date in the payload that is not after today, else today
# (`PlaidAccount#holdings_snapshot_date`).
#
# A row the old processor left later than that date (a holding priced ahead of
# today, or an undated one written on the day of a sync that came after the
# newest price date) stays the account's newest provider date. Every reader of
# current holdings takes the provider rows on that one date, so it would show
# only the stale row, at its old quantity, and hide the whole new snapshot
# until the price dates caught up -- for good, for a row priced far ahead.
# Plaid does not delete holdings at sync (`PlaidAdapter#can_delete_holdings?`
# is false), so nothing else would remove it.
#
# Removed: rows owned by a Plaid account provider and dated after the snapshot
# date of that Plaid account's stored payload. That is exactly the set the
# processor can no longer write and the readers would otherwise pick. Rows of
# other providers, and rows with no provider (calculated or manual), are left
# alone. Running it again removes nothing more.
#
# Balances and holdings history were computed with the removed rows, so each
# Plaid item that lost rows is synced again to rebuild them.
class RemovePlaidHoldingsAheadOfTheirSnapshot < ActiveRecord::Migration[8.1]
  # Each account's DELETE commits on its own, so row locks are not held for
  # the whole scan, and the syncs scheduled at the end read committed rows.
  # Safe to interrupt: a rerun picks up where it stopped.
  disable_ddl_transaction!

  # The processor's rule, copied rather than called, so the migration keeps
  # meaning what it meant when it was written.
  def self.snapshot_date(payload, today: Date.current)
    holdings = payload.is_a?(Hash) ? Array(payload["holdings"]) : []
    dates = holdings.filter_map do |holding|
      value = holding.is_a?(Hash) ? holding["institution_price_as_of"] : nil
      next if value.blank?

      Date.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    dates.reject { |date| date > today }.max || today
  end

  BATCH_SIZE = 100

  # The payload is read through a model, not raw SQL: where Active Record
  # encryption is configured, PlaidAccount encrypts raw_holdings_payload, and a
  # raw read would see ciphertext and no price dates. This declares it under
  # the same condition PlaidAccount does (Encryptable#encryption_ready?), and
  # is built when the migration runs so it takes the configuration of then.
  def self.plaid_account_payloads
    Class.new(ActiveRecord::Base) do
      self.table_name = "plaid_accounts"
      def self.name = "RemovePlaidHoldingsAheadOfTheirSnapshot::PlaidAccountPayload"
      encrypts :raw_holdings_payload if ActiveRecordEncryptionConfig.explicitly_configured?
    end
  end

  def up
    schedule_syncs(remove_stale_rows(batch_size: BATCH_SIZE))
  end

  # In batches, so neither every Plaid payload nor every provider id is held at
  # once; one DELETE per account provider. Returns the ids of the Plaid items
  # that lost rows.
  def remove_stale_rows(batch_size:)
    item_ids = []

    self.class.plaid_account_payloads
      .joins("JOIN account_providers ON account_providers.provider_id = plaid_accounts.id")
      .where(account_providers: { provider_type: "PlaidAccount" })
      .select("plaid_accounts.id", "plaid_accounts.plaid_item_id", "plaid_accounts.raw_holdings_payload",
              "account_providers.id AS account_provider_id")
      .find_each(batch_size: batch_size) do |plaid_account|
        cutoff = self.class.snapshot_date(plaid_account.raw_holdings_payload)

        removed = connection.delete(ActiveRecord::Base.sanitize_sql_array([
          "DELETE FROM holdings WHERE account_provider_id = ? AND date > ?", plaid_account.account_provider_id, cutoff
        ]))
        item_ids << plaid_account.plaid_item_id if removed.positive?
      end

    item_ids.uniq
  end

  # The removed rows were stale copies of positions the next Plaid sync writes
  # again on its snapshot date. Putting them back would hide that snapshot
  # again, and their old quantities are not kept anywhere to restore.
  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private
    def schedule_syncs(item_ids)
      PlaidItem.syncable.where(id: item_ids).find_each do |item|
        item.sync_later
      rescue => e
        say "Could not schedule a sync for Plaid item #{item.id} (#{e.message}); it refreshes on its next sync"
      end
    end
end
