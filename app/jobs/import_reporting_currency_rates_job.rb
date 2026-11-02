# Fetches the exchange rates a family's reporting currencies need, for every
# account in its history (disabled ones included, as the net-worth series
# counts them up to when they were disabled), after a currency is added to
# them in preferences.
class ImportReportingCurrencyRatesJob < ApplicationJob
  queue_as :medium_priority

  # For every family with an additional reporting currency: run when an
  # exchange rate provider becomes available, as the rates skipped while there
  # was none would otherwise wait for each account's next sync.
  def self.perform_later_for_reporting_families
    Family.where.not(enabled_currencies: nil).find_each do |family|
      perform_later(family) if (family.reporting_currency_codes - [ family.primary_currency_code ]).any?
    end
  end

  def perform(family)
    return unless ExchangeRate.provider

    family.accounts.historical.find_each do |account|
      Account::MarketDataImporter.new(account).import_exchange_rates
    end
  end
end
