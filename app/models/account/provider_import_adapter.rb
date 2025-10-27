class Account::ProviderImportAdapter
  attr_reader :account

  def initialize(account)
    @account = account
  end

  # Imports a transaction from a provider
  #
  # @param external_id [String] Unique identifier from the provider (e.g., "plaid_12345", "simplefin_abc")
  # @param amount [BigDecimal, Numeric] Transaction amount
  # @param currency [String] Currency code (e.g., "USD")
  # @param date [Date, String] Transaction date
  # @param name [String] Transaction name/description
  # @param source [String] Provider name (e.g., "plaid", "simplefin")
  # @param category_id [Integer, nil] Optional category ID
  # @param merchant [Merchant, nil] Optional merchant object
  # @return [Entry] The created or updated entry
  def import_transaction(external_id:, amount:, currency:, date:, name:, source:, category_id: nil, merchant: nil)
    raise ArgumentError, "external_id is required" if external_id.blank?
    raise ArgumentError, "source is required" if source.blank?

    Account.transaction do
      entry = account.entries.find_or_initialize_by(plaid_id: external_id) do |e|
        e.entryable = Transaction.new
      end

      entry.assign_attributes(
        amount: amount,
        currency: currency,
        date: date
      )

      # Use enrichment pattern to respect user overrides
      entry.enrich_attribute(:name, name, source: source)

      # Enrich transaction-specific attributes
      if category_id
        entry.transaction.enrich_attribute(:category_id, category_id, source: source)
      end

      if merchant
        entry.transaction.enrich_attribute(:merchant_id, merchant.id, source: source)
      end

      entry.save!
      entry
    end
  end

  # Finds or creates a merchant from provider data
  #
  # @param provider_merchant_id [String] Provider's merchant ID
  # @param name [String] Merchant name
  # @param source [String] Provider name (e.g., "plaid", "simplefin")
  # @param website_url [String, nil] Optional merchant website
  # @param logo_url [String, nil] Optional merchant logo URL
  # @return [ProviderMerchant, nil] The merchant object or nil if data is insufficient
  def find_or_create_merchant(provider_merchant_id:, name:, source:, website_url: nil, logo_url: nil)
    return nil unless provider_merchant_id.present? && name.present?

    ProviderMerchant.find_or_create_by!(
      source: source,
      name: name
    ) do |m|
      m.provider_merchant_id = provider_merchant_id
      m.website_url = website_url
      m.logo_url = logo_url
    end
  end

  # Updates account balance from provider data
  #
  # @param balance [BigDecimal, Numeric] Total balance
  # @param cash_balance [BigDecimal, Numeric] Cash balance (for investment accounts)
  # @param source [String] Provider name (for logging/debugging)
  def update_balance(balance:, cash_balance: nil, source: nil)
    account.update!(
      balance: balance,
      cash_balance: cash_balance || balance
    )
  end

  # Imports a holding (investment position) from a provider
  #
  # @param security [Security] The security object
  # @param quantity [BigDecimal, Numeric] Number of shares/units
  # @param amount [BigDecimal, Numeric] Total value in account currency
  # @param currency [String] Currency code
  # @param date [Date, String] Holding date
  # @param price [BigDecimal, Numeric, nil] Price per share (optional)
  # @param source [String] Provider name
  # @return [Holding] The created holding
  def import_holding(security:, quantity:, amount:, currency:, date:, price: nil, source:)
    raise ArgumentError, "security is required" if security.nil?
    raise ArgumentError, "source is required" if source.blank?

    holding = account.holdings.create!(
      security: security,
      qty: quantity,
      amount: amount,
      currency: currency,
      date: date,
      price: price
    )

    holding
  end

  # Imports a trade (investment transaction) from a provider
  #
  # @param security [Security] The security object
  # @param quantity [BigDecimal, Numeric] Number of shares (negative for sells, positive for buys)
  # @param price [BigDecimal, Numeric] Price per share
  # @param amount [BigDecimal, Numeric] Total trade value
  # @param currency [String] Currency code
  # @param date [Date, String] Trade date
  # @param name [String, nil] Optional custom name for the trade
  # @param source [String] Provider name
  # @return [Entry] The created entry with trade
  def import_trade(security:, quantity:, price:, amount:, currency:, date:, name: nil, source:)
    raise ArgumentError, "security is required" if security.nil?
    raise ArgumentError, "source is required" if source.blank?

    Account.transaction do
      trade = Trade.new(
        security: security,
        qty: quantity,
        price: price,
        currency: currency
      )

      # Generate name if not provided
      trade_name = if name.present?
        name
      else
        trade_type = quantity.negative? ? "sell" : "buy"
        Trade.build_name(trade_type, quantity, security.ticker)
      end

      entry = account.entries.create!(
        date: date,
        amount: amount,
        currency: currency,
        name: trade_name,
        entryable: trade
      )

      entry
    end
  end
end
