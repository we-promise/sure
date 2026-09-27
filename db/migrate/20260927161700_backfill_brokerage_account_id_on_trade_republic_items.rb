# CodeRabbit review on #3754: the previous migration only excludes NULL
# brokerage_account_id from the new unique index, so an item connected before
# this feature existed (session configured, but the column never set) stays
# unclaimed and would slip past duplicate_connection?'s new column check.
# Backfill from each item's own already-synced portfolio account -- the only
# source available without calling the live provider from a migration. An
# item with a valid session that has never synced even once is not covered
# here; its own regular sync sets trade_republic_accounts and closes the
# window from that point on, same as a freshly created item today.
class BackfillBrokerageAccountIdOnTradeRepublicItems < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE trade_republic_items
      SET brokerage_account_id = portfolio.trade_republic_account_id
      FROM trade_republic_accounts AS portfolio
      WHERE portfolio.trade_republic_item_id = trade_republic_items.id
        AND portfolio.kind = 'portfolio'
        AND portfolio.trade_republic_account_id IS NOT NULL
        AND trade_republic_items.brokerage_account_id IS NULL
    SQL
  end

  def down
  end
end
