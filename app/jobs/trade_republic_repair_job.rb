class TradeRepublicRepairJob < ApplicationJob
  queue_as :low_priority

  def perform(trade_republic_item)
    attempted = false
    trade_republic_item.trade_republic_accounts.includes(account_provider: :account).each do |provider_account|
      next unless provider_account.usable_account.present?

      begin
        # Set before processing: the processor commits its writes and then
        # broadcasts, so a raise here can follow committed changes.
        attempted = true
        TradeRepublicAccount::Processor.new(provider_account).process
      rescue => e
        DebugLogEntry.capture(
          category: "sync",
          level: "error",
          message: "TradeRepublicRepairJob - Failed to repair account #{provider_account.id}: #{e.message}",
          source: "trade_republic",
          family: trade_republic_item.family,
          provider_key: "trade_republic",
          account_provider_id: provider_account.account_provider&.id,
          metadata: { trade_republic_account_id: provider_account.id }
        )
      end
    end

    # A repair rewrites entries and holdings outside a sync, and the cached
    # exchange rate note currencies key on this column.
    trade_republic_item.family.touch(:latest_sync_activity_at) if attempted
  end
end
