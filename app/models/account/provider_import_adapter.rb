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
      entry = account.entries.find_or_initialize_by(external_id: external_id, source: source) do |e|
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
      provider_merchant_id: provider_merchant_id,
      source: source
    ) do |m|
      m.name = name
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

  # Imports or updates a holding (investment position) from a provider
  #
  # @param security [Security] The security object
  # @param quantity [BigDecimal, Numeric] Number of shares/units
  # @param amount [BigDecimal, Numeric] Total value in account currency
  # @param currency [String] Currency code
  # @param date [Date, String] Holding date
  # @param price [BigDecimal, Numeric, nil] Price per share (optional)
  # @param cost_basis [BigDecimal, Numeric, nil] Cost basis (optional)
  # @param external_id [String, nil] Provider's unique ID (optional, for deduplication)
  # @param source [String] Provider name
  # @param account_provider_id [String, nil] The AccountProvider ID that owns this holding (optional)
  # @param delete_future_holdings [Boolean] Whether to delete holdings after this date (default: false)
  # @return [Holding] The created or updated holding
  def import_holding(security:, quantity:, amount:, currency:, date:, price: nil, cost_basis: nil, external_id: nil, source:, account_provider_id: nil, delete_future_holdings: false)
    raise ArgumentError, "security is required" if security.nil?
    raise ArgumentError, "source is required" if source.blank?

    Account.transaction do
      # Two strategies for finding/creating holdings:
      # 1. By external_id (SimpleFin approach) - tracks each holding uniquely
      # 2. By security+date+currency (Plaid approach) - overwrites holdings for same security/date
      holding = if external_id.present?
        account.holdings.find_or_initialize_by(external_id: external_id) do |h|
          h.security = security
          h.date = date
          h.currency = currency
        end
      else
        account.holdings.find_or_initialize_by(
          security: security,
          date: date,
          currency: currency
        )
      end

      holding.assign_attributes(
        security: security,
        date: date,
        currency: currency,
        qty: quantity,
        price: price,
        amount: amount,
        cost_basis: cost_basis,
        account_provider_id: account_provider_id
      )

      holding.save!

      # Optionally delete future holdings for this security (Plaid behavior)
      # Only delete if ALL providers allow deletion (cross-provider check)
      if delete_future_holdings
        unless account.can_delete_holdings?
          Rails.logger.warn(
            "Skipping future holdings deletion for account #{account.id} " \
            "because not all providers allow deletion"
          )
          return holding
        end

        # Build base query for future holdings
        future_holdings_query = account.holdings
          .where(security: security)
          .where("date > ?", date)

        # If account_provider_id is provided, only delete holdings from this provider
        # This prevents deleting positions imported by other providers
        if account_provider_id.present?
          future_holdings_query = future_holdings_query.where(account_provider_id: account_provider_id)
        end

        future_holdings_query.destroy_all
      end

      holding
    end
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
  # @param external_id [String, nil] Provider's unique ID (optional, for deduplication)
  # @param source [String] Provider name
  # @return [Entry] The created entry with trade
  def import_trade(security:, quantity:, price:, amount:, currency:, date:, name: nil, external_id: nil, source:)
    raise ArgumentError, "security is required" if security.nil?
    raise ArgumentError, "source is required" if source.blank?

    Account.transaction do
      # Generate name if not provided
      trade_name = if name.present?
        name
      else
        trade_type = quantity.negative? ? "sell" : "buy"
        Trade.build_name(trade_type, quantity, security.ticker)
      end

      # Use find_or_initialize_by with external_id if provided, otherwise create new
      entry = if external_id.present?
        account.entries.find_or_initialize_by(external_id: external_id, source: source) do |e|
          e.entryable = Trade.new(
            security: security,
            qty: quantity,
            price: price,
            currency: currency
          )
        end
      else
        account.entries.new(
          entryable: Trade.new(
            security: security,
            qty: quantity,
            price: price,
            currency: currency
          )
        )
      end

      entry.assign_attributes(
        date: date,
        amount: amount,
        currency: currency,
        name: trade_name
      )

      entry.save!
      entry
    end
  end

  # Updates accountable-specific attributes (e.g., credit card details, loan details)
  #
  # @param attributes [Hash] Hash of attributes to update on the accountable
  # @param source [String] Provider name (for logging/debugging)
  # @return [Boolean] Whether the update was successful
  def update_accountable_attributes(attributes:, source:)
    return false unless account.accountable.present?
    return false if attributes.blank?

    # Filter out nil values and only update attributes that exist on the accountable
    valid_attributes = attributes.compact.select do |key, _|
      account.accountable.respond_to?("#{key}=")
    end

    return false if valid_attributes.empty?

    account.accountable.update!(valid_attributes)
    true
  rescue => e
    Rails.logger.error("Failed to update #{account.accountable_type} attributes from #{source}: #{e.message}")
    false
  end
end
