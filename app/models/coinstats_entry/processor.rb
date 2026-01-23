# Processes a single CoinStats transaction into a local Transaction record.
# Extracts amount, date, and metadata from the CoinStats API format.
#
# CoinStats API transaction structure (from /wallet/transactions endpoint):
# {
#   type: "Sent" | "Received" | "Swap" | ...,
#   date: "2025-06-07T11:58:11.000Z",
#   coinData: { count: -0.00636637, symbol: "ETH", currentValue: 29.21 },
#   profitLoss: { profit: -13.41, profitPercent: -84.44, currentValue: 29.21 },
#   hash: { id: "0x...", explorerUrl: "https://etherscan.io/tx/0x..." },
#   fee: { coin: { id, name, symbol, icon }, count: 0.00003, totalWorth: 0.08 },
#   transactions: [{ action: "Sent", items: [{ id, count, totalWorth, coin: {...} }] }]
# }
class CoinstatsEntry::Processor
  include CoinstatsTransactionIdentifiable

  # @param coinstats_transaction [Hash] Raw transaction data from API
  # @param coinstats_account [CoinstatsAccount] Parent account for context
  def initialize(coinstats_transaction, coinstats_account:)
    @coinstats_transaction = coinstats_transaction
    @coinstats_account = coinstats_account
  end

  # Imports the transaction into the linked account.
  # @return [Transaction, nil] Created transaction or nil if no linked account
  # @raise [ArgumentError] If transaction data is invalid
  # @raise [StandardError] If import fails
  def process
    unless account.present?
      Rails.logger.warn "CoinstatsEntry::Processor - No linked account for coinstats_account #{coinstats_account.id}, skipping transaction #{external_id}"
      return nil
    end

    import_adapter.import_transaction(
      external_id: external_id,
      amount: amount,
      currency: currency,
      date: date,
      name: name,
      source: "coinstats",
      merchant: merchant,
      notes: notes,
      extra: extra_metadata
    )
  rescue ArgumentError => e
    Rails.logger.error "CoinstatsEntry::Processor - Validation error for transaction #{external_id rescue 'unknown'}: #{e.message}"
    raise
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    Rails.logger.error "CoinstatsEntry::Processor - Failed to save transaction #{external_id rescue 'unknown'}: #{e.message}"
    raise StandardError.new("Failed to import transaction: #{e.message}")
  rescue => e
    Rails.logger.error "CoinstatsEntry::Processor - Unexpected error processing transaction #{external_id rescue 'unknown'}: #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise StandardError.new("Unexpected error importing transaction: #{e.message}")
  end

  private

    attr_reader :coinstats_transaction, :coinstats_account

    def extra_metadata
      cs = {}

      # Store transaction hash and explorer URL
      if hash_data.present?
        cs["transaction_hash"] = hash_data[:id] if hash_data[:id].present?
        cs["explorer_url"] = hash_data[:explorerUrl] if hash_data[:explorerUrl].present?
      end

      # Store transaction type
      cs["transaction_type"] = transaction_type if transaction_type.present?

      # Store coin/token info
      if coin_data.present?
        cs["symbol"] = coin_data[:symbol] if coin_data[:symbol].present?
        cs["count"] = coin_data[:count] if coin_data[:count].present?
      end

      # Store profit/loss info
      if profit_loss.present?
        cs["profit"] = profit_loss[:profit] if profit_loss[:profit].present?
        cs["profit_percent"] = profit_loss[:profitPercent] if profit_loss[:profitPercent].present?
      end

      # Store fee info
      if fee_data.present?
        cs["fee_amount"] = fee_data[:count] if fee_data[:count].present?
        cs["fee_symbol"] = fee_data.dig(:coin, :symbol) if fee_data.dig(:coin, :symbol).present?
        cs["fee_usd"] = fee_data[:totalWorth] if fee_data[:totalWorth].present?
      end

      return nil if cs.empty?
      { "coinstats" => cs }
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      coinstats_account.current_account
    end

    def data
      @data ||= coinstats_transaction.with_indifferent_access
    end

    # Helper accessors for nested data structures
    def hash_data
      @hash_data ||= (data[:hash] || {}).with_indifferent_access
    end

    def coin_data
      @coin_data ||= (data[:coinData] || {}).with_indifferent_access
    end

    def profit_loss
      @profit_loss ||= (data[:profitLoss] || {}).with_indifferent_access
    end

    def fee_data
      @fee_data ||= (data[:fee] || {}).with_indifferent_access
    end

    def transactions_data
      @transactions_data ||= data[:transactions] || []
    end

    def transaction_type
      data[:type]
    end

    def external_id
      tx_id = extract_coinstats_transaction_id(data)
      raise ArgumentError, "CoinStats transaction missing unique identifier: #{data.inspect}" unless tx_id.present?
      "coinstats_#{tx_id}"
    end

    def name
      tx_type = transaction_type || "Transaction"
      symbol = coin_data[:symbol]

      # Get coin name from nested transaction items if available (used as fallback)
      coin_name = transactions_data.dig(0, :items, 0, :coin, :name)

      if symbol.present?
        "#{tx_type} #{symbol}"
      elsif coin_name.present?
        "#{tx_type} #{coin_name}"
      else
        tx_type.to_s
      end
    end

    def amount
      # Use currentValue from coinData (USD value) or profitLoss
      usd_value = coin_data[:currentValue] || profit_loss[:currentValue] || 0

      parsed_amount = case usd_value
      when String
        BigDecimal(usd_value)
      when Numeric
        BigDecimal(usd_value.to_s)
      else
        BigDecimal("0")
      end

      absolute_amount = parsed_amount.abs

      # App convention: negative amount = income (inflow), positive amount = expense (outflow)
      # coinData.count is negative for outgoing transactions
      coin_count = coin_data[:count] || 0

      if coin_count.to_f < 0 || outgoing_transaction_type?
        # Outgoing transaction = expense = positive
        absolute_amount
      else
        # Incoming transaction = income = negative
        -absolute_amount
      end
    rescue ArgumentError => e
      Rails.logger.error "Failed to parse CoinStats transaction amount: #{usd_value.inspect} - #{e.message}"
      raise
    end

    def outgoing_transaction_type?
      tx_type = (transaction_type || "").to_s.downcase
      %w[sent send sell withdraw transfer_out swap_out].include?(tx_type)
    end

    def currency
      # CoinStats values are always in USD
      "USD"
    end

    def date
      # CoinStats returns date as ISO 8601 string (e.g., "2025-06-07T11:58:11.000Z")
      timestamp = data[:date]

      raise ArgumentError, "CoinStats transaction missing date" unless timestamp.present?

      case timestamp
      when Integer, Float
        Time.at(timestamp).to_date
      when String
        Time.parse(timestamp).to_date
      when Time, DateTime
        timestamp.to_date
      when Date
        timestamp
      else
        Rails.logger.error("CoinStats transaction has invalid date format: #{timestamp.inspect}")
        raise ArgumentError, "Invalid date format: #{timestamp.inspect}"
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.error("CoinStats transaction date parsing failed: #{e.message}")
      raise ArgumentError, "Invalid date format: #{timestamp.inspect}"
    end

    def merchant
      # Use the coinstats_account as the merchant source for consistency
      # All transactions from the same account will have the same merchant and logo
      merchant_name = coinstats_account.name
      return nil unless merchant_name.present?

      # Use the account's logo (token icon) for the merchant
      logo = coinstats_account.institution_metadata&.dig("logo")

      # Use the coinstats_account ID to ensure consistent merchant per account
      @merchant ||= import_adapter.find_or_create_merchant(
        provider_merchant_id: "coinstats_account_#{coinstats_account.id}",
        name: merchant_name,
        source: "coinstats",
        logo_url: logo
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "CoinstatsEntry::Processor - Failed to create merchant '#{merchant_name}': #{e.message}"
      nil
    end

    def notes
      parts = []

      # Include coin/token details with count
      symbol = coin_data[:symbol]
      count = coin_data[:count]
      if count.present? && symbol.present?
        parts << "#{count} #{symbol}"
      end

      # Include fee info
      if fee_data[:count].present? && fee_data.dig(:coin, :symbol).present?
        parts << "Fee: #{fee_data[:count]} #{fee_data.dig(:coin, :symbol)}"
      end

      # Include profit/loss info
      if profit_loss[:profit].present?
        profit_formatted = profit_loss[:profit].to_f.round(2)
        percent_formatted = profit_loss[:profitPercent].to_f.round(2)
        parts << "P/L: $#{profit_formatted} (#{percent_formatted}%)"
      end

      # Include explorer URL for reference
      if hash_data[:explorerUrl].present?
        parts << "Explorer: #{hash_data[:explorerUrl]}"
      end

      parts.presence&.join(" | ")
    end
end
