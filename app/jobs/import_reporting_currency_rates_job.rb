# Fetches the exchange rates a family's reporting currencies need, for every
# account in its history (disabled ones included, as the net-worth series
# counts them up to when they were disabled), after a currency is added to
# them in preferences. Accounts in one currency need the same pairs, so each
# pair is imported once, from the earliest date any account needs it, as
# Family::MarketDataRefresher does.
class ImportReportingCurrencyRatesJob < ApplicationJob
  queue_as :medium_priority

  def perform(family)
    return unless ExchangeRate.provider

    pair_dates = {}
    family.accounts.historical.find_each do |account|
      Account::MarketDataImporter.new(account).exchange_rate_pair_dates.each do |pair, start_date|
        pair_dates[pair] = [ pair_dates[pair], start_date ].compact.min
      end
    end

    pair_dates.each do |(from, to), start_date|
      ExchangeRate.import_provider_rates(from: from, to: to, start_date: start_date, end_date: Date.current)
    end
  end
end
