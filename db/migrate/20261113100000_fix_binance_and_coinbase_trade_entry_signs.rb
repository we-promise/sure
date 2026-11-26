# Binance spot/futures trades and Coinbase buys and sells were written with
# their cash flow inverted: a buy as money arriving, a sell as money leaving.
# The processors are fixed, but both skip an entry whose external_id they
# already have, so a resync never revisits the rows they wrote before.
#
# The trade's quantity already carried the right sign, so it decides: a Buy or
# Sell entry whose amount disagrees with its trade's quantity is flipped. Other
# Coinbase activity (staking rewards, transfers) shares the coinbase_txn_
# prefix but is signed on purpose, so only Buy and Sell trades are touched. A
# row that already agrees is left alone, which makes the migration safe to run
# more than once, and an entry the user edited is left for them.
#
# As with FixKrakenTradeEntrySigns, the balance series is rebuilt on each
# account's next sync; nothing is queued from here.
class FixBinanceAndCoinbaseTradeEntrySigns < ActiveRecord::Migration[8.1]
  def up
    flipped = execute(<<~'SQL').to_a
      UPDATE entries
      SET amount = -amount
      WHERE entryable_type = 'Trade'
        AND user_modified = false
        AND amount <> 0
        AND (
          (source = 'binance' AND (external_id LIKE 'binance\_spot\_%' OR external_id LIKE 'binance\_futures\_%'))
          OR (source = 'coinbase' AND (external_id LIKE 'coinbase\_txn\_%' OR external_id LIKE 'coinbase\_buy\_%' OR external_id LIKE 'coinbase\_sell\_%'))
        )
        AND EXISTS (
          SELECT 1 FROM trades
          WHERE trades.id = entries.entryable_id
            AND trades.investment_activity_label IN ('Buy', 'Sell')
            AND trades.qty <> 0
            AND SIGN(trades.qty) <> SIGN(entries.amount)
        )
      RETURNING account_id
    SQL

    return say "No inverted Binance or Coinbase trade entries found" if flipped.empty?

    accounts = flipped.map { |row| row["account_id"] }.uniq
    say "Flipped #{flipped.size} Binance and Coinbase trade entries across #{accounts.size} accounts; " \
        "their balance series are rebuilt on their next sync"
  end

  # The rows that were flipped cannot be told apart afterwards from rows that
  # were right to begin with, so there is nothing to put back.
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
