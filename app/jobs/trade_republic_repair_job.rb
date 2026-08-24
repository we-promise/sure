class TradeRepublicRepairJob < ApplicationJob
  queue_as :low_priority

  def perform(trade_republic_item)
    trade_republic_item.trade_republic_accounts.includes(account_provider: :account).each do |provider_account|
      next unless provider_account.current_account.present?

      begin
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
  end
end
