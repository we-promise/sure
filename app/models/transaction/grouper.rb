class Transaction::Grouper
  Group = Data.define(:grouping_key, :display_name, :entries, :merchant, :transaction_type)

  # Returns the active grouping strategy class.
  # Change this method to swap algorithms without touching the wizard.
  def self.strategy
    Transaction::Grouper::ByMerchantOrName
  end

  # Use stored transaction-date rates so rendering a group never waits on a provider.
  # A single missing rate makes the whole total unavailable.
  def self.total_in(entries, currency:)
    foreign_currencies = entries.map(&:currency).uniq - [ currency ]
    rates = ExchangeRate.where(from_currency: foreign_currencies, to_currency: currency, date: entries.map(&:date).uniq)
                        .index_by { |rate| [ rate.from_currency, rate.date ] }

    entries.sum(Money.new(0, currency)) do |entry|
      amount = entry.amount_money.abs
      next amount if entry.currency == currency

      rate = rates[[ entry.currency, entry.date ]]
      return unless rate

      amount.exchange_to(currency, date: entry.date, custom_rate: rate.rate)
    end
  end

  # @param entries [ActiveRecord::Relation] pre-scoped entries to group (caller controls authorization)
  # @param limit [Integer] max number of groups to return
  # @param offset [Integer] number of groups to skip (for pagination)
  # @return [Array<Group>]
  def self.call(entries, limit: 20, offset: 0)
    raise NotImplementedError, "#{name} must implement .call"
  end
end
