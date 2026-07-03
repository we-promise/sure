# frozen_string_literal: true

class WiseAccount::Processor
  include WiseAccount::DataHelpers

  # Wise balance statement API v1 sign convention:
  #   amount.value is SIGNED: positive when the balance increases (CREDIT),
  #   negative when the balance decreases (DEBIT / spending).
  #
  # Sure sign convention (Entry#amount):
  #   negative = inflow  (money comes in, balance increases)
  #   positive = outflow (money goes out, balance decreases)
  #
  # Therefore: signed_amount = -amount.value (simple negation for both types)

  def initialize(wise_account)
    @wise_account = wise_account
  end

  def process
    account = @wise_account.current_account
    return unless account

    Rails.logger.info "WiseAccount::Processor - Processing wise_account #{@wise_account.id} -> account #{account.id}"

    update_account_balance(account)
    process_transactions
    account.broadcast_sync_complete

    { transactions_processed: transactions.size }
  end

  private

    def update_account_balance(account)
      balance = @wise_account.current_balance
      return if balance.nil?

      account.update!(
        balance:      balance,
        cash_balance: balance,
        currency:     @wise_account.currency || account.currency
      )
      account.set_current_balance(balance)
    end

    def process_transactions
      import_adapter = Account::ProviderImportAdapter.new(@wise_account.current_account)

      transactions.each do |raw|
        process_transaction(raw.with_indifferent_access, import_adapter)
      rescue => e
        DebugLogEntry.capture(
          category: "provider_sync",
          level: "error",
          message: "WiseAccount::Processor - Failed to process transaction: #{e.message}",
          source: "WiseAccount::Processor",
          provider_key: "wise"
        )
      end
    end

    def transactions
      payload = @wise_account.raw_transactions_payload
      payload = payload.with_indifferent_access[:transactions] if payload.is_a?(Hash)
      Array(payload)
    end

    def process_transaction(data, import_adapter)
      amount_data = (data[:amount] || {}).with_indifferent_access
      amount_value = parse_decimal(amount_data[:value])
      return if amount_value.nil?

      signed_amount = -amount_value

      date = parse_date(data[:date]) || Date.current
      currency = (amount_data[:currency] || @wise_account.currency).to_s.upcase
      name = transaction_name(data)
      external_id = "wise_#{data[:referenceNumber] || transaction_fallback_key(data)}"

      import_adapter.import_transaction(
        external_id: external_id,
        amount:      signed_amount,
        currency:    currency,
        date:        date,
        name:        name,
        source:      "wise"
      )
    end

    def transaction_name(data)
      details = (data[:details] || {}).with_indifferent_access
      details[:description].presence ||
        details[:type].to_s.humanize.presence ||
        data[:type].to_s.capitalize
    end

    # Fallback dedup key when referenceNumber is absent (very old transactions)
    def transaction_fallback_key(data)
      amount_data = (data[:amount] || {}).with_indifferent_access
      Digest::SHA256.hexdigest(
        [ data[:date], data[:type], amount_data[:value], amount_data[:currency] ].join("|")
      ).first(24)
    end
end
