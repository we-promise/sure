# Imports the exchange rates an institution's accounts need to be charted in
# the currency its entry is shown in (Account::MarketDataImporter), for every
# account the entry counts, without syncing them: the user choosing the
# currency may only be able to view some of them.
class ImportInstitutionRatesJob < ApplicationJob
  queue_as :scheduled

  def perform(account_ids)
    Account.where(id: account_ids).find_each do |account|
      Account::MarketDataImporter.new(account).import_exchange_rates
    end
  end
end
