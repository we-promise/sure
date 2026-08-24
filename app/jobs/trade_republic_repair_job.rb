class TradeRepublicRepairJob < ApplicationJob
  queue_as :low_priority

  def perform(trade_republic_item)
    trade_republic_item.trade_republic_accounts.includes(account_provider: :account).each do |provider_account|
      next unless provider_account.current_account.present?

      TradeRepublicAccount::Processor.new(provider_account).process
    end
  end
end
