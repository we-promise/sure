class TinkoffInvestItem::SyncCompleteEvent
  attr_reader :tinkoff_invest_item

  def initialize(tinkoff_invest_item)
    @tinkoff_invest_item = tinkoff_invest_item
  end

  def broadcast
    tinkoff_invest_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    tinkoff_invest_item.family.broadcast_sync_complete
  end
end
