class KrakenAccount::Processor
  LEDGER_LABELS = {
    "deposit" => "Contribution",
    "withdrawal" => "Withdrawal",
    "transfer" => "Transfer",
    "staking" => "Interest",
    "dividend" => "Dividend",
    "rollover" => "Interest",
    "credit" => "Interest",
    "receive" => "Contribution",
    "spend" => "Withdrawal",
    "sale" => "Other",
    "settled" => "Other",
    "margin" => "Other",
    "nft_rebate" => "Other"
  }.freeze

  attr_reader :kraken_account

  def initialize(kraken_account)
    @kraken_account = kraken_account
  end

  def process
    return unless kraken_account.current_account.present?

    process_holdings
    process_account!
    process_trades
    process_ledgers
  end

  private

    def account
      kraken_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def process_holdings
      KrakenAccount::HoldingsProcessor.new(kraken_account).process
    rescue => e
      Rails.logger.error("KrakenAccount::Processor - Failed to process holdings for #{kraken_account.id}: #{e.class} - #{e.message}")
    end

    def process_account!
      native_value = calculate_native_balance

      account.update!(
        balance: native_value,
        cash_balance: fiat_asset? ? native_value : 0,
        currency: native_currency
      )
    end

    def calculate_native_balance
      native_amount = kraken_account.raw_payload&.dig("native_balance", "amount")
      return native_amount.to_d if native_amount.present?
      return (kraken_account.current_balance || 0).to_d if fiat_asset?

      latest_holding = account.holdings.where(date: Date.current).sum(:amount)
      return latest_holding if latest_holding.positive?

      0
    end

    def process_trades
      Array(kraken_account.raw_transactions_payload&.dig("trades")).each do |trade|
        process_trade(trade.with_indifferent_access)
      end
    rescue => e
      Rails.logger.error("KrakenAccount::Processor - Failed to process trades for #{kraken_account.id}: #{e.class} - #{e.message}")
    end

    def process_trade(trade)
      pair = trade[:normalized_pair].is_a?(Hash) ? trade[:normalized_pair].with_indifferent_access : nil
      return unless pair

      type = trade[:type].to_s.downcase
      return unless %w[buy sell].include?(type)
      return if kraken_provider&.fiat_asset?(pair[:base])

      security = find_or_create_security(pair[:base])
      return unless security

      quantity = trade[:vol].to_d.abs
      return if quantity.zero?

      quantity = -quantity if type == "sell"

      cost = trade[:cost].to_d.abs
      fee = trade[:fee].to_d.abs
      amount = type == "sell" ? (cost - fee) : -(cost + fee)
      price = trade[:price].present? ? trade[:price].to_d : (cost / quantity.abs).round(8)
      date = parse_time(trade[:time])

      import_adapter.import_trade(
        external_id: "kraken_trade_#{trade[:id]}",
        security: security,
        quantity: quantity,
        price: price,
        amount: amount,
        currency: pair[:quote] || native_currency,
        date: date,
        name: "#{type.titleize} #{pair[:base]}",
        source: "kraken",
        activity_label: type == "buy" ? "Buy" : "Sell"
      )
    end

    def process_ledgers
      Array(kraken_account.raw_transactions_payload&.dig("ledgers")).each do |ledger|
        process_ledger(ledger.with_indifferent_access)
      end
    rescue => e
      Rails.logger.error("KrakenAccount::Processor - Failed to process ledgers for #{kraken_account.id}: #{e.class} - #{e.message}")
    end

    def process_ledger(ledger)
      ledger_type = ledger[:type].to_s.downcase
      return if ledger_type == "trade"

      amount = ledger[:amount].to_d
      return if amount.zero?

      label = LEDGER_LABELS[ledger_type]
      return unless label.present?

      currency = kraken_provider&.normalize_asset_code(ledger[:asset]) || kraken_account.currency
      date = parse_time(ledger[:time])

      import_adapter.import_transaction(
        external_id: "kraken_ledger_#{ledger[:id]}",
        amount: amount,
        currency: currency,
        date: date,
        name: "#{label} #{currency}",
        source: "kraken",
        extra: {
          "kraken" => {
            "ledger_type" => ledger_type,
            "refid" => ledger[:refid],
            "balance" => ledger[:balance]
          }.compact
        },
        investment_activity_label: label
      )
    end

    def find_or_create_security(asset_code)
      ticker = asset_code.to_s.include?(":") ? asset_code.to_s : "CRYPTO:#{asset_code}"

      Security::Resolver.new(ticker).resolve
    rescue => e
      Rails.logger.warn("KrakenAccount::Processor - Resolver failed for #{ticker}: #{e.class} - #{e.message}; creating offline security")

      Security.find_or_initialize_by(ticker: ticker).tap do |security|
        security.offline = true if security.respond_to?(:offline=) && security.offline != true
        security.name = asset_code if security.name.blank?
        security.save! if security.changed?
      end
    end

    def parse_time(value)
      Time.zone.at(value.to_f).to_date
    rescue
      Date.current
    end

    def native_currency
      kraken_account.raw_payload&.dig("native_balance", "currency") || account.currency || "USD"
    end

    def fiat_asset?
      ActiveModel::Type::Boolean.new.cast(kraken_account.raw_payload&.dig("fiat_asset"))
    end

    def kraken_provider
      @kraken_provider ||= kraken_account.kraken_item&.kraken_provider
    end
end
