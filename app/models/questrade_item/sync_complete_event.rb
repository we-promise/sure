class QuestradeItem::SyncCompleteEvent
  attr_reader :questrade_item

  def initialize(questrade_item)
    @questrade_item = questrade_item
  end

  def broadcast
    questrade_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    questrade_item.family.broadcast_sync_complete
  end
end
