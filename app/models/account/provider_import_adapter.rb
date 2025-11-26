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
  # @param notes [String, nil] Optional transaction notes/memo
  # @param extra [Hash, nil] Optional provider-specific metadata to merge into transaction.extra
  # @return [Entry] The created or updated entry
  def import_transaction(external_id:, amount:, currency:, date:, name:, source:, category_id: nil, merchant: nil, notes: nil, extra: nil)
    raise ArgumentError, "external_id is required" if external_id.blank?
    raise ArgumentError, "source is required" if source.blank?

    Account.transaction do
      # Find or initialize by both external_id AND source
      # This allows multiple providers to sync same account with separate entries
      entry = account.entries.find_or_initialize_by(external_id: external_id, source: source) do |e|
        e.entryable = Transaction.new
      end

      # If this is a new entry, check for potential duplicates from manual/CSV imports
      # This handles the case where a user manually created or CSV imported a transaction
      # before linking their account to a provider
      # Note: We don't pass name here to allow matching even when provider formats names differently
      if entry.new_record?
        duplicate = find_duplicate_transaction(date: date, amount: amount, currency: currency)
        if duplicate
          # "Claim" the duplicate by updating its external_id and source
          # This prevents future duplicate checks from matching it again
          entry = duplicate
          entry.assign_attributes(external_id: external_id, source: source)
        end
      end

      # Validate entryable type matches to prevent external_id collisions
      if entry.persisted? && !entry.entryable.is_a?(Transaction)
        raise ArgumentError, "Entry with external_id '#{external_id}' already exists with different entryable type: #{entry.entryable_type}"
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

      if notes.present? && entry.respond_to?(:enrich_attribute)
        entry.enrich_attribute(:notes, notes, source: source)
      end

      # Persist extra provider metadata on the transaction (non-enriched; always merged)
      if extra.present? && entry.entryable.is_a?(Transaction)
        existing = entry.transaction.extra || {}
        incoming = extra.is_a?(Hash) ? extra.deep_stringify_keys : {}
        entry.transaction.extra = existing.deep_merge(incoming)
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
      holding = nil

      if external_id.present?
        # Preferred path: match by provider's external_id
        holding = account.holdings.find_by(external_id: external_id)

        unless holding
          # Fallback path: match by (security, date, currency) — and when provided,
          # also scope by account_provider_id to avoid cross‑provider claiming.
          # This keeps behavior symmetric with deletion logic below which filters
          # by account_provider_id when present.
          find_by_attrs = {
            security: security,
            date: date,
            currency: currency
          }
          if account_provider_id.present?
            find_by_attrs[:account_provider_id] = account_provider_id
          end

          holding = account.holdings.find_by(find_by_attrs)
        end

        holding ||= account.holdings.new(
          security: security,
          date: date,
          currency: currency,
          account_provider_id: account_provider_id
        )
      else
        holding = account.holdings.find_or_initialize_by(
          security: security,
          date: date,
          currency: currency
        )
      end

      # Early cross-provider composite-key conflict guard: avoid attempting a write
      # that would violate a unique index on (account_id, security_id, date, currency).
      if external_id.present?
        existing_composite = account.holdings.find_by(
          security: security,
          date: date,
          currency: currency
        )

        if existing_composite &&
           account_provider_id.present? &&
           existing_composite.account_provider_id.present? &&
           existing_composite.account_provider_id != account_provider_id
          Rails.logger.warn(
            "ProviderImportAdapter: cross-provider holding collision for account=#{account.id} security=#{security.id} date=#{date} currency=#{currency}; returning existing id=#{existing_composite.id}"
          )
          return existing_composite
        end
      end

      holding.assign_attributes(
        security: security,
        date: date,
        currency: currency,
        qty: quantity,
        price: price,
        amount: amount,
        cost_basis: cost_basis,
        account_provider_id: account_provider_id,
        external_id: external_id
      )

      begin
        Holding.transaction(requires_new: true) do
          holding.save!
        end
      rescue ActiveRecord::RecordNotUnique => e
        # Handle unique index collisions on (account_id, security_id, date, currency)
        # that can occur when another provider (or concurrent import) already
        # created a row for this composite key. Use the existing row and keep
        # the outer transaction valid by isolating the error in a savepoint.
        existing = account.holdings.find_by(
          security: security,
          date: date,
          currency: currency
        )

        if existing
          # If an existing row belongs to a different provider, do NOT claim it.
          # Keep cross-provider isolation symmetrical with deletion logic.
          if account_provider_id.present? && existing.account_provider_id.present? && existing.account_provider_id != account_provider_id
            Rails.logger.warn(
              "ProviderImportAdapter: cross-provider holding collision for account=#{account.id} security=#{security.id} date=#{date} currency=#{currency}; returning existing id=#{existing.id}"
            )
            holding = existing
          else
            # Same provider (or unowned). Apply latest snapshot and attach external_id for idempotency.
            updates = {
              qty: quantity,
              price: price,
              amount: amount,
              cost_basis: cost_basis
            }

            # Adopt the row to this provider if it’s currently unowned
            if account_provider_id.present? && existing.account_provider_id.nil?
              updates[:account_provider_id] = account_provider_id
            end

            # Attach external_id if provided and missing
            if external_id.present? && existing.external_id.blank?
              updates[:external_id] = external_id
            end

            begin
              # Use update_columns to avoid validations and keep this collision handler best-effort.
              existing.update_columns(updates.compact)
            rescue => _
              # Best-effort only; avoid raising in collision handler
            end

            holding = existing
          end
        else
          # Could not find an existing row; re-raise original error
          raise e
        end
      end

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
        # Find or initialize by both external_id AND source
        # This allows multiple providers to sync same account with separate entries
        account.entries.find_or_initialize_by(external_id: external_id, source: source) do |e|
          e.entryable = Trade.new
        end
      else
        account.entries.new(
          entryable: Trade.new,
          source: source
        )
      end

      # Validate entryable type matches to prevent external_id collisions
      if entry.persisted? && !entry.entryable.is_a?(Trade)
        raise ArgumentError, "Entry with external_id '#{external_id}' already exists with different entryable type: #{entry.entryable_type}"
      end

      # Always update Trade attributes (works for both new and existing records)
      entry.entryable.assign_attributes(
        security: security,
        qty: quantity,
        price: price,
        currency: currency
      )

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

  # Finds a potential duplicate transaction from manual entry or CSV import
  # Matches on date, amount, currency, and optionally name
  # Only matches transactions without external_id (manual/CSV imported)
  #
  # @param date [Date, String] Transaction date
  # @param amount [BigDecimal, Numeric] Transaction amount
  # @param currency [String] Currency code
  # @param name [String, nil] Optional transaction name for more accurate matching
  # @param exclude_entry_ids [Set, Array, nil] Entry IDs to exclude from the search (e.g., already claimed entries)
  # @return [Entry, nil] The duplicate entry or nil if not found
  def find_duplicate_transaction(date:, amount:, currency:, name: nil, exclude_entry_ids: nil)
    # Convert date to Date object if it's a string
    date = Date.parse(date.to_s) unless date.is_a?(Date)

    # Look for entries on the same account with:
    # 1. Same date
    # 2. Same amount (exact match)
    # 3. Same currency
    # 4. No external_id (manual/CSV imported transactions)
    # 5. Entry type is Transaction (not Trade or Valuation)
    # 6. Optionally same name (if name parameter is provided)
    # 7. Not in the excluded IDs list (if provided)
    query = account.entries
                   .where(entryable_type: "Transaction")
                   .where(date: date)
                   .where(amount: amount)
                   .where(currency: currency)
                   .where(external_id: nil)

    # Add name filter if provided
    query = query.where(name: name) if name.present?

    # Exclude already claimed entries if provided
    query = query.where.not(id: exclude_entry_ids) if exclude_entry_ids.present?

    query.order(created_at: :asc).first
  end
end
