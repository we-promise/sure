# Every Kraken trade entry was written with its cash flow inverted: a buy as
# money arriving, a sell as money leaving. The processor is fixed, but it
# skips an entry whose external_id it already has, so a resync never revisits
# the rows it wrote before -- and the balance series, derived by walking back
# from today through those flows, stays wrong for every existing account.
#
# The trade's quantity already carried the right sign, so it decides: an entry
# whose amount disagrees with its trade's quantity is flipped. The magnitude is
# kept as stored; `Entry.amount` and the trade's fields are separate values and
# this is not the place to recompute one from the other. A row that already
# agrees is left alone, which makes the migration safe to run more than once.
#
# An entry the user edited is theirs, whatever it says, and is left for them.
#
# The persisted balance series was derived from the wrong flows, so each
# account touched gets a sync, which rebuilds the whole series for a linked
# account -- the same follow-through as cleanup_orphaned_currency_balances,
# with two differences that make the rebuild certain rather than likely. The
# UPDATE is committed before anything is queued, so no sync can read the
# entries mid-flip. And the sync is a fresh record run after Sync::VISIBLE_FOR
# instead of `sync_later`, which would reuse a sync already in flight -- one
# that may have materialized the old flows moments before the commit.
class FixKrakenTradeEntrySigns < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    flipped = execute(<<~SQL).to_a
      UPDATE entries
      SET amount = -amount
      WHERE source = 'kraken'
        AND external_id LIKE 'kraken\\_trade\\_%'
        AND entryable_type = 'Trade'
        AND user_modified = false
        AND amount <> 0
        AND EXISTS (
          SELECT 1 FROM trades
          WHERE trades.id = entries.entryable_id
            AND trades.qty <> 0
            AND SIGN(trades.qty) <> SIGN(entries.amount)
        )
      RETURNING account_id
    SQL

    account_ids = flipped.map { |row| row["account_id"] }.uniq
    return say "No inverted Kraken trade entries found" if account_ids.empty?

    say "Flipped #{flipped.size} Kraken trade entries across #{account_ids.size} accounts"

    if defined?(Account) && defined?(SyncJob) && defined?(Sync)
      Account.where(id: account_ids).find_each do |account|
        sync = account.syncs.create!
        SyncJob.set(wait: Sync::VISIBLE_FOR).perform_later(sync)
      end
      say "Queued a balance rebuild for #{account_ids.size} accounts"
    else
      say "Please sync these accounts to rebuild their balances: #{account_ids.join(', ')}"
    end
  end

  # The rows that were flipped cannot be told apart afterwards from rows that
  # were right to begin with, so there is nothing to put back.
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
