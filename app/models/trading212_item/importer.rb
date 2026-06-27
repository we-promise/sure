class Trading212Item::Importer
  attr_reader :trading212_item, :provider

  def initialize(trading212_item, provider:)
    @trading212_item = trading212_item
    @provider = provider
  end

  def import
    ActiveRecord::Base.transaction do
      instruments = fetch_instruments
      trading212_item.update!(raw_instruments_payload: instruments, status: :good)

      summary = provider.fetch_account_summary
      account_id = summary["id"]&.to_s
      cash_data = (summary["cash"] || {}).with_indifferent_access

      # T212 account summary structure:
      #   totalValue                   – total portfolio value (cash + investments)
      #   cash.availableToTrade        – free cash
      #   cash.reservedForOrders       – cash locked in pending orders
      #   investments.currentValue     – current market value of open positions
      cash_balance = parse_decimal(cash_data[:availableToTrade])
      current_balance = parse_decimal(summary["totalValue"]) || BigDecimal("0")

      currency = trading212_item.currency.presence || trading212_item.family.currency

      t212_account = trading212_item.trading212_accounts.find_or_initialize_by(trading212_account_id: account_id)
      t212_account.assign_attributes(
        name: build_account_name(account_id),
        currency: currency,
        current_balance: current_balance,
        cash_balance: cash_balance,
        raw_positions_payload: provider.fetch_positions,
        raw_orders_payload: provider.fetch_all_orders,
        raw_dividends_payload: provider.fetch_all_dividends,
        raw_transactions_payload: provider.fetch_all_transactions,
        last_positions_sync: Time.current,
        last_orders_sync: Time.current
      )
      t212_account.save!
    end

    { success: true }
  end

  private

    def fetch_instruments
      provider.fetch_instruments
    rescue => e
      Rails.logger.warn("Trading212Item::Importer - Failed to fetch instruments: #{e.message}. Using cached payload.")
      Array(trading212_item.raw_instruments_payload)
    end

    def build_account_name(account_id)
      base = I18n.t("trading212_items.defaults.name")
      account_id.present? ? "#{base} (#{account_id})" : base
    end

    def parse_decimal(value)
      return BigDecimal("0") if value.nil?
      BigDecimal(value.to_s)
    rescue ArgumentError
      BigDecimal("0")
    end
end
