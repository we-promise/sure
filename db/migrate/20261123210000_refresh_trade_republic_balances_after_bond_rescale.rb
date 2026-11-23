# frozen_string_literal: true

# Workers can run alongside db:prepare. Do not enqueue this refresh from the
# October price correction: device_id and session_expires_at do not exist yet.
# Refresh all linked portfolios once, including installations that already ran
# the correction (or whose earlier refresh failed). The old migration did not
# persist the affected item IDs, and corrected prices cannot identify them now.
class RefreshTradeRepublicBalancesAfterBondRescale < ActiveRecord::Migration[8.1]
  def up
    TradeRepublicItem.reset_column_information
    item_ids = TradeRepublicAccount.where(kind: "portfolio").joins(:account_provider).select(:trade_republic_item_id)

    TradeRepublicItem.syncable.where(id: item_ids).find_each do |item|
      item.sync_later
    end
  end

  def down
    # A refresh does not need to be undone.
  end
end
