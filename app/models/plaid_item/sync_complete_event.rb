class PlaidItem::SyncCompleteEvent
  attr_reader :plaid_item

  def initialize(plaid_item)
    @plaid_item = plaid_item
  end

  def broadcast
    plaid_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    plaid_item.family.broadcast_sync_complete
  end
end
