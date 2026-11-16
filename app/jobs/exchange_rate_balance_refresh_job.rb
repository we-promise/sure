# Syncs the accounts whose balances converted at exchange rates a write just
# stored or changed (ExchangeRate::BalanceRefresh). A job rather than inline,
# because the write can sit inside a sync's open transaction or a request.
class ExchangeRateBalanceRefreshJob < ApplicationJob
  queue_as :low_priority

  # `rates` is [{ "from" =>, "to" =>, "date" => }] as the writers enqueue it.
  def perform(rates)
    ExchangeRate::BalanceRefresh.schedule(rates.map { |rate| rate.to_h.symbolize_keys })
  end
end
