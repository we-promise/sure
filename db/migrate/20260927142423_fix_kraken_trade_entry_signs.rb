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
class FixKrakenTradeEntrySigns < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
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
    SQL
  end

  # The rows that were flipped cannot be told apart afterwards from rows that
  # were right to begin with, so there is nothing to put back.
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
