require "digest/md5"

# Imports one TrueLayer transaction as a Sure entry.
#
# Sign convention: Sure stores outflows as positive amounts. TrueLayer reports
# account debits as negative, but card charges as positive (money owed), so
# account amounts are negated and card amounts are kept.
class TruelayerEntry::Processor
  include CurrencyNormalizable

  def initialize(truelayer_transaction, truelayer_account:)
    @data = truelayer_transaction.with_indifferent_access
    @truelayer_account = truelayer_account
  end

  def process
    return nil unless account.present?

    import_adapter.import_transaction(
      external_id: external_id,
      amount: amount,
      currency: currency,
      date: date,
      name: name,
      source: "truelayer",
      merchant: merchant,
      notes: notes,
      extra: extra_metadata,
      replace_extra_namespaces: [ "truelayer" ]
    )
  end

  private

    attr_reader :data, :truelayer_account

    def account
      @account ||= truelayer_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def external_id
      id = TruelayerAccount.transaction_id_for(data)
      raise ArgumentError, "TrueLayer transaction has no id" if id.blank?

      "truelayer_#{id}"
    end

    def description
      data[:description].to_s.strip.presence
    end

    # The merchant name when the bank supplies one, else its description.
    def name
      data[:merchant_name].to_s.strip.presence || description || "Unknown transaction"
    end

    def notes
      description
    end

    # A merchant only when the bank names one. Transfer and direct debit
    # descriptions carry references and dates, so each would otherwise become
    # a merchant of its own.
    def merchant
      merchant_name = data[:merchant_name].to_s.strip
      return nil if merchant_name.blank?

      import_adapter.find_or_create_merchant(
        provider_merchant_id: "truelayer_merchant_#{Digest::MD5.hexdigest(merchant_name.downcase)}",
        name: merchant_name,
        source: "truelayer"
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "TruelayerEntry::Processor - Failed to create merchant '#{merchant_name}': #{e.message}"
      nil
    end

    def amount
      value = BigDecimal(data[:amount].to_s, exception: false)
      raise ArgumentError, "TrueLayer transaction has no usable amount: #{data[:amount].inspect}" unless value&.finite?

      truelayer_account.card? ? value : -value
    end

    def currency
      parse_currency(data[:currency]) || truelayer_account.currency || account.currency
    end

    # The bank's own calendar date, as written in the timestamp, so a
    # transaction near midnight doesn't move day with the time zone.
    def date
      Date.iso8601(data[:timestamp].to_s[0, 10])
    rescue Date::Error
      raise ArgumentError, "Invalid TrueLayer transaction timestamp: #{data[:timestamp].inspect}"
    end

    def extra_metadata
      {
        truelayer: {
          transaction_id: data[:transaction_id],
          provider_transaction_id: data[:provider_transaction_id],
          transaction_type: data[:transaction_type],
          transaction_category: data[:transaction_category],
          classification: data[:transaction_classification].presence,
          running_balance: data.dig(:running_balance, :amount)
        }.compact
      }
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' in TrueLayer transaction #{external_id}")
    end
end
