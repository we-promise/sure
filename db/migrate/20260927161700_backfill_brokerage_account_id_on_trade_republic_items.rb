# Items connected before brokerage_account_id existed claim it from their
# synced portfolio account; items that never synced are covered by their next
# sync instead. Families can already hold several active items for the same
# account, and the unique index allows only one claim per account, so the
# oldest item wins and ids another active item already holds are skipped.
class BackfillBrokerageAccountIdOnTradeRepublicItems < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE trade_republic_items
      SET brokerage_account_id = claims.account_id
      FROM (
        SELECT DISTINCT ON (items.family_id, portfolio.trade_republic_account_id)
          items.id AS item_id,
          portfolio.trade_republic_account_id AS account_id
        FROM trade_republic_items AS items
        JOIN trade_republic_accounts AS portfolio
          ON portfolio.trade_republic_item_id = items.id
         AND portfolio.kind = 'portfolio'
         AND portfolio.trade_republic_account_id IS NOT NULL
        WHERE items.brokerage_account_id IS NULL
          AND items.scheduled_for_deletion = false
        ORDER BY items.family_id, portfolio.trade_republic_account_id, items.created_at, items.id
      ) AS claims
      WHERE trade_republic_items.id = claims.item_id
        AND NOT EXISTS (
          SELECT 1
          FROM trade_republic_items AS claimed
          WHERE claimed.family_id = trade_republic_items.family_id
            AND claimed.brokerage_account_id = claims.account_id
            AND claimed.scheduled_for_deletion = false
        )
    SQL
  end

  def down
  end
end
