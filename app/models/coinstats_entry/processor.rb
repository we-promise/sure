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

  EXCHANGE_TRADE_TYPES = %w[buy sell swap trade convert fill].freeze

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

    if exchange_trade? && trade_security.present?
      remove_legacy_transaction_entry!

      import_adapter.import_trade(
        external_id: external_id,
        security: trade_security,
        quantity: trade_quantity,
        price: trade_price,
        amount: trade_amount,
        currency: currency,
        date: date,
        name: name,
        source: "coinstats",
        activity_label: trade_activity_label
      )
    else
      import_adapter.import_transaction(
        external_id: external_id,
        amount: amount,
        currency: currency,
        date: date,
        name: name,
        source: "coinstats",
        merchant: merchant,
        notes: notes,
        extra: extra_metadata,
        investment_activity_label: transaction_activity_label
      )
    end
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

      if matched_item.present?
        cs["matched_item"] = {
          "count" => matched_item[:count],
          "total_worth" => matched_item[:totalWorth],
          "coin_id" => matched_item.dig(:coin, :id),
          "coin_symbol" => matched_item.dig(:coin, :symbol)
        }.compact
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
        if fee_data[:totalWorth].present?
          cs["fee_value"] = fee_data[:totalWorth]
          cs["fee_usd"] = fee_data[:totalWorth]
        end
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
      data[:type] || data[:transactionType]
    end

    def external_id
      tx_id = extract_coinstats_transaction_id(data)
      raise ArgumentError, "CoinStats transaction missing unique identifier: #{data.inspect}" unless tx_id.present?
      "coinstats_#{tx_id}"
    end

    def name
      tx_type = transaction_type || "Transaction"
      symbol = matched_symbol || coin_data[:symbol]

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
      if portfolio_exchange_account?
        absolute_amount = matched_item_total_worth.abs.nonzero? ||
          coin_data[:currentValue].to_d.abs ||
          profit_loss[:currentValue].to_d.abs

        return outgoing_transaction_type? ? absolute_amount : -absolute_amount
      end

      if coinstats_account.exchange_source? && coinstats_account.fiat_asset?
        fiat_value = matched_item_total_worth.abs
        absolute_amount = fiat_value.positive? ? fiat_value : coin_data[:count].to_d.abs
        return outgoing_transaction_type? ? absolute_amount : -absolute_amount
      end

      raw_value =
        if coinstats_account.exchange_source?
          matched_item_total_worth.nonzero? || coin_data[:currentValue] || profit_loss[:currentValue] || 0
        else
          coin_data[:currentValue] || profit_loss[:currentValue] || 0
        end

      parsed_amount = case raw_value
      when String
        BigDecimal(raw_value)
      when Numeric
        BigDecimal(raw_value.to_s)
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
      Rails.logger.error "Failed to parse CoinStats transaction amount: #{data.inspect} - #{e.message}"
      raise
    end

    def outgoing_transaction_type?
      tx_type = (transaction_type || "").to_s.downcase
      %w[sent send sell withdraw transfer_out swap_out].include?(tx_type)
    end

    def currency
      account.currency || coinstats_account.currency || "USD"
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
      symbol = matched_symbol || coin_data[:symbol]
      count = trade_item_count.nonzero? || coin_data[:count]
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
        parts << "P/L: #{formatted_currency_amount(profit_formatted)} (#{percent_formatted}%)"
      end

      # Include explorer URL for reference
      if hash_data[:explorerUrl].present?
        parts << "Explorer: #{hash_data[:explorerUrl]}"
      end

      parts.presence&.join(" | ")
    end

    def exchange_trade?
      return false unless coinstats_account.exchange_source?
      return false if coinstats_account.fiat_asset?
      return false if trade_quantity.zero? || trade_price.zero?

      EXCHANGE_TRADE_TYPES.include?(normalized_transaction_type)
    end

    def trade_security
      symbol = trade_item&.dig(:coin, :symbol) || matched_symbol || coinstats_account.asset_symbol
      return if symbol.blank?

      Security::Resolver.new(symbol.start_with?("CRYPTO:") ? symbol : "CRYPTO:#{symbol}").resolve
    end

    def trade_quantity
      trade_item_count.nonzero? || matched_item_count.nonzero? || coin_data[:count].to_d
    end

    def trade_price
      @trade_price ||= begin
        quantity = trade_quantity.abs
        return 0.to_d if quantity.zero?

        value = trade_item_total_worth.nonzero? || matched_item_total_worth.nonzero? || coin_data[:currentValue] || coin_data[:totalWorth] || profit_loss[:currentValue] || 0
        BigDecimal(value.to_s).abs / quantity
      rescue ArgumentError
        0.to_d
      end
    end

    def trade_amount
      trade_quantity * trade_price
    end

    def trade_activity_label
      normalized_transaction_type == "sell" || trade_quantity.negative? ? "Sell" : "Buy"
    end

    def transaction_activity_label
      case normalized_transaction_type
      when "buy" then "Buy"
      when "sell" then "Sell"
      when "swap", "trade", "convert" then "Other"
      when "received", "receive", "deposit", "transfer_in", "roll_in" then "Transfer"
      when "sent", "send", "withdraw", "transfer_out", "roll_out" then "Transfer"
      when "reward", "interest" then "Interest"
      when "dividend" then "Dividend"
      when "fee" then "Fee"
      else
        "Other"
      end
    end

    def normalized_transaction_type
      @normalized_transaction_type ||= transaction_type.to_s.downcase.parameterize(separator: "_")
    end

    def remove_legacy_transaction_entry!
      legacy_entry = account.entries.find_by(
        external_id: external_id,
        source: "coinstats",
        entryable_type: "Transaction"
      )

      legacy_entry&.destroy!
    end

    def matched_symbol
      matched_item&.dig(:coin, :symbol)
    end

    def matched_item
      @matched_item ||= begin
        return primary_portfolio_item if portfolio_exchange_account?

        items = transaction_items
        account_id = coinstats_account.account_id.to_s.downcase
        account_symbol = coinstats_account.asset_symbol.to_s.downcase

        items.find do |item|
          coin = item[:coin].to_h.with_indifferent_access
          coin[:id]&.to_s&.downcase == account_id ||
            coin[:identifier]&.to_s&.downcase == account_id ||
            coin[:symbol]&.to_s&.downcase == account_symbol
        end
      end
    end

    def trade_item
      @trade_item ||= portfolio_exchange_account? ? portfolio_trade_item : matched_item
    end

    def trade_item_count
      trade_item&.[](:count).to_d
    end

    def trade_item_total_worth
      trade_item&.[](:totalWorth).to_d
    end

    def matched_item_count
      matched_item&.[](:count).to_d
    end

    def matched_item_total_worth
      matched_item&.[](:totalWorth).to_d
    end

    def portfolio_exchange_account?
      coinstats_account.exchange_portfolio_account?
    end

    def portfolio_trade_item
      crypto_items = transaction_items.reject { |item| portfolio_fiat_item?(item) || item[:count].to_d.zero? }
      crypto_items.find { |item| item[:count].to_d.positive? } || crypto_items.first
    end

    def primary_portfolio_item
      portfolio_trade_item ||
        transaction_items.find { |item| item[:count].to_d.nonzero? } ||
        transaction_items.first
    end

    def portfolio_fiat_item?(item)
      coinstats_account.fiat_asset?(item[:coin] || item)
    end

    def transaction_items
      @transaction_items ||= begin
        Array(transactions_data).flat_map do |entry|
          Array(entry.with_indifferent_access[:items]).map(&:with_indifferent_access)
        end +
          Array(data[:transfers]).flat_map do |entry|
            Array(entry.with_indifferent_access[:items]).map(&:with_indifferent_access)
          end
      end
    end

    def formatted_currency_amount(amount)
      return "$#{amount}" if currency == "USD"

      "#{amount} #{currency}"
    end
end
