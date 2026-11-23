class Transaction::Grouper
  Group = Data.define(:grouping_key, :display_name, :entries, :merchant, :transaction_type)

  # Returns the active grouping strategy class.
  # Change this method to swap algorithms without touching the wizard.
  def self.strategy
    Transaction::Grouper::ByMerchantOrName
  end

  # A missing transaction-date rate makes the whole group total unavailable.
  def self.total_in(entries, currency:)
    native, foreign = entries.partition { |entry| entry.currency == currency }
    total = Money.new(native.sum { |entry| entry.amount.abs }, currency)
    rates = ExchangeRate.where(to_currency: currency, from_currency: foreign.pluck(:currency).uniq, date: foreign.pluck(:date).uniq)
                        .index_by { |rate| [ rate.from_currency, rate.date ] }

    foreign.sum(total) do |entry|
      rate = rates.fetch([ entry.currency, entry.date ]) { return nil }
      entry.amount_money.exchange_to(currency, custom_rate: rate.rate).abs
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
