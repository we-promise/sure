class Account::ProviderImportAdapter
  attr_reader :account, :skipped_entries

  def initialize(account)
    @account = account
    @skipped_entries = []
  end

  # Resets skipped entries tracking (call at start of new sync batch)
  def reset_skipped_entries!
    @skipped_entries = []
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
  # @param pending_transaction_id [String, nil] Plaid's linking ID for pending→posted reconciliation
  # @param extra [Hash, nil] Optional provider-specific metadata to merge into transaction.extra
  # @param investment_activity_label [String, nil] Optional activity type label (e.g., "Buy", "Dividend")
  # @return [Entry] The created or updated entry
  def import_transaction(external_id:, amount:, currency:, date:, name:, source:, category_id: nil, merchant: nil, notes: nil, pending_transaction_id: nil, extra: nil, investment_activity_label: nil)
    raise ArgumentError, "external_id is required" if external_id.blank?
    raise ArgumentError, "source is required" if source.blank?

    Account.transaction do
      # Find or initialize by both external_id AND source
      # This allows multiple providers to sync same account with separate entries
      entry = account.entries.find_or_initialize_by(external_id: external_id, source: source) do |e|
        e.entryable = Transaction.new
      end

      # === TYPE COLLISION CHECK: Must happen before protection check ===
      # If entry exists but is a different type (e.g., Trade), that's an error.
      # This prevents external_id collisions across different entryable types.
      if entry.persisted? && !entry.entryable.is_a?(Transaction)
        raise ArgumentError, "Entry with external_id '#{external_id}' already exists with different entryable type: #{entry.entryable_type}"
      end

      # === PROTECTION CHECK: Skip entries that should not be overwritten ===
      # Check persisted Transaction entries for protection flags before making changes.
      # This prevents sync from overwriting user edits, CSV imports, or excluded entries.
      if entry.persisted?
        skip_reason = determine_skip_reason(entry)
        if skip_reason
          record_skip(entry, skip_reason)
          return entry
        end
      end

      # If this is a new entry, check for potential duplicates from manual/CSV imports
      # This handles the case where a user manually created or CSV imported a transaction
      # before linking their account to a provider
      # Note: We don't pass name here to allow matching even when provider formats names differently
      if entry.new_record?
        duplicate = find_duplicate_transaction(date: date, amount: amount, currency: currency)
        if duplicate
          # Check if duplicate is protected - if so, link but don't modify
          if duplicate.protected_from_sync?
            duplicate.update!(external_id: external_id, source: source)
            record_skip(duplicate, determine_skip_reason(duplicate) || "protected")
            return duplicate
          end

          # "Claim" the unprotected duplicate by updating its external_id and source
          # This prevents future duplicate checks from matching it again
          entry = duplicate
          entry.assign_attributes(external_id: external_id, source: source)
        end
      end

      # If still a new entry and this is a POSTED transaction, check for matching pending transactions
      incoming_pending = false
      if extra.is_a?(Hash)
        pending_extra = extra.with_indifferent_access
        incoming_pending =
          ActiveModel::Type::Boolean.new.cast(pending_extra.dig("simplefin", "pending")) ||
          ActiveModel::Type::Boolean.new.cast(pending_extra.dig("plaid", "pending")) ||
          ActiveModel::Type::Boolean.new.cast(pending_extra.dig("lunchflow", "pending"))
      end

      if entry.new_record? && !incoming_pending
        pending_match = nil

        # PRIORITY 1: Use Plaid's pending_transaction_id if provided (most reliable)
        # Plaid explicitly links pending→posted with this ID - no guessing required
        if pending_transaction_id.present?
          pending_match = account.entries.find_by(external_id: pending_transaction_id, source: source)
          if pending_match
            Rails.logger.info("Reconciling pending→posted via Plaid pending_transaction_id: claiming entry #{pending_match.id} (#{pending_match.name}) with new external_id #{external_id}")
          end
        end

        # PRIORITY 2: Fallback to EXACT amount match (for SimpleFIN and providers without linking IDs)
        # Only searches backward in time - pending date must be <= posted date
        if pending_match.nil?
          pending_match = find_pending_transaction(date: date, amount: amount, currency: currency, source: source)
          if pending_match
            Rails.logger.info("Reconciling pending→posted via exact amount match: claiming entry #{pending_match.id} (#{pending_match.name}) with new external_id #{external_id}")
          end
        end

        if pending_match
          entry = pending_match
          entry.assign_attributes(external_id: external_id)
        end
      end

      # Track if this is a new posted transaction (for fuzzy suggestion after save)
      is_new_posted = entry.new_record? && !incoming_pending

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
        entry.transaction.save!
      end

      # Auto-detect investment activity labels for investment accounts
      detected_label = investment_activity_label
      if account.investment? && detected_label.nil? && entry.entryable.is_a?(Transaction)
        detected_label = detect_activity_label(name, amount)
      end

      # Auto-set kind for internal movements and contributions
      auto_kind = nil
      auto_category = nil
      if Transaction::INTERNAL_MOVEMENT_LABELS.include?(detected_label)
        auto_kind = "funds_movement"
      elsif detected_label == "Contribution"
        auto_kind = "investment_contribution"
        auto_category = account.family.investment_contributions_category
      end

      # Set investment activity label, kind, and category if detected
      if entry.entryable.is_a?(Transaction)
        if detected_label.present? && entry.transaction.investment_activity_label.blank?
          entry.transaction.assign_attributes(investment_activity_label: detected_label)
        end

        if auto_kind.present?
          entry.transaction.assign_attributes(kind: auto_kind)
        end

        if auto_category.present? && entry.transaction.category_id.blank?
          entry.transaction.assign_attributes(category: auto_category)
        end
      end

      entry.save!
      entry.transaction.save! if entry.transaction.changed?

      # AFTER save: For NEW posted transactions, check for fuzzy matches to SUGGEST (not auto-claim)
      # This handles tip adjustments where auto-matching is too risky
      if is_new_posted
        # PRIORITY 1: Try medium-confidence fuzzy match (≤30% amount difference)
        fuzzy_suggestion = find_pending_transaction_fuzzy(
          date: date,
          amount: amount,
          currency: currency,
          source: source,
          merchant_id: merchant&.id,
          name: name
        )
        if fuzzy_suggestion
          # Store suggestion on the PENDING entry for user to review
          begin
            store_duplicate_suggestion(
              pending_entry: fuzzy_suggestion,
              posted_entry: entry,
              reason: "fuzzy_amount_match",
              posted_amount: amount,
              confidence: "medium"
            )
            Rails.logger.info("Suggested potential duplicate (medium confidence): pending entry #{fuzzy_suggestion.id} (#{fuzzy_suggestion.name}, #{fuzzy_suggestion.amount}) may match posted #{entry.name} (#{amount})")
          rescue ActiveRecord::RecordInvalid => e
            Rails.logger.warn("Failed to store duplicate suggestion for entry #{fuzzy_suggestion.id}: #{e.message}")
          end
        else
          # PRIORITY 2: Try low-confidence match (>30% to 100% difference - big tips)
          low_confidence_suggestion = find_pending_transaction_low_confidence(
            date: date,
            amount: amount,
            currency: currency,
            source: source,
            merchant_id: merchant&.id,
            name: name
          )
          if low_confidence_suggestion
            begin
              store_duplicate_suggestion(
                pending_entry: low_confidence_suggestion,
                posted_entry: entry,
                reason: "low_confidence_match",
                posted_amount: amount,
                confidence: "low"
              )
              Rails.logger.info("Suggested potential duplicate (low confidence): pending entry #{low_confidence_suggestion.id} (#{low_confidence_suggestion.name}, #{low_confidence_suggestion.amount}) may match posted #{entry.name} (#{amount})")
            rescue ActiveRecord::RecordInvalid => e
              Rails.logger.warn("Failed to store duplicate suggestion for entry #{low_confidence_suggestion.id}: #{e.message}")
            end
          end
        end
      end

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

    # First try to find by provider_merchant_id (stable identifier derived from normalized name)
    # This handles case variations in merchant names (e.g., "ACME Corp" vs "Acme Corp")
    merchant = ProviderMerchant.find_by(provider_merchant_id: provider_merchant_id, source: source)

    # If not found by provider_merchant_id, try by exact name match (backwards compatibility)
    merchant ||= ProviderMerchant.find_by(source: source, name: name)

    if merchant
      # Update logo if provided and merchant doesn't have one (or has a different one)
      # Best-effort: don't fail transaction import if logo update fails
      if logo_url.present? && merchant.logo_url != logo_url
        begin
          merchant.update!(logo_url: logo_url)
        rescue StandardError => e
          Rails.logger.warn("Failed to update merchant logo: merchant_id=#{merchant.id} logo_url=#{logo_url} error=#{e.message}")
        end
      end
      return merchant
    end

    # Create new merchant
    begin
      merchant = ProviderMerchant.create!(
        source: source,
        name: name,
        provider_merchant_id: provider_merchant_id,
        website_url: website_url,
        logo_url: logo_url
      )
    rescue ActiveRecord::RecordNotUnique
      # Race condition - another process created the record
      merchant = ProviderMerchant.find_by(provider_merchant_id: provider_merchant_id, source: source) ||
                 ProviderMerchant.find_by(source: source, name: name)
    end

    merchant
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
          # Fallback path 1a: match by provider_security (for remapped holdings)
          # This allows re-matching a holding that was remapped to a different security
          # Scope by account_provider_id to avoid cross-provider overwrites
          fallback_1a_attrs = {
            provider_security: security,
            date: date,
            currency: currency
          }
          fallback_1a_attrs[:account_provider_id] = account_provider_id if account_provider_id.present?
          holding = account.holdings.find_by(fallback_1a_attrs)

          # Fallback path 1b: match by provider_security ticker (for remapped holdings when
          # Security::Resolver returns a different security instance for the same ticker)
          # Scope by account_provider_id to avoid cross-provider overwrites
          # Skip if ticker is blank to avoid matching NULL tickers
          unless holding || security.ticker.blank?
            scope = account.holdings
              .joins("INNER JOIN securities AS ps ON ps.id = holdings.provider_security_id")
              .where(date: date, currency: currency)
              .where("ps.ticker = ?", security.ticker)
            scope = scope.where(account_provider_id: account_provider_id) if account_provider_id.present?
            holding = scope.first
          end

          # Fallback path 2: match by (security, date, currency) — and when provided,
          # also scope by account_provider_id to avoid cross‑provider claiming.
          # This keeps behavior symmetric with deletion logic below which filters
          # by account_provider_id when present.
          unless holding
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

      # Reconcile cost_basis to respect priority hierarchy
      reconciled = Holding::CostBasisReconciler.reconcile(
        existing_holding: holding.persisted? ? holding : nil,
        incoming_cost_basis: cost_basis,
        incoming_source: "provider"
      )

      # Build base attributes
      attributes = {
        date: date,
        currency: currency,
        qty: quantity,
        price: price,
        amount: amount,
        account_provider_id: account_provider_id,
        external_id: external_id
      }

      # Only update security if not locked by user
      if holding.new_record? || holding.security_replaceable_by_provider?
        attributes[:security] = security
        # Track the provider's original security so reset_security_to_provider! works
        # Only set if not already set (preserves original if user remapped then unlocked)
        attributes[:provider_security_id] = security.id if holding.provider_security_id.blank?
      end

      # Only update cost_basis if reconciliation says to
      if reconciled[:should_update]
        attributes[:cost_basis] = reconciled[:cost_basis]
        attributes[:cost_basis_source] = reconciled[:cost_basis_source]
      end

      holding.assign_attributes(attributes)

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
              amount: amount
            }

            # Reconcile cost_basis to respect priority hierarchy
            collision_reconciled = Holding::CostBasisReconciler.reconcile(
              existing_holding: existing,
              incoming_cost_basis: cost_basis,
              incoming_source: "provider"
            )

            if collision_reconciled[:should_update]
              updates[:cost_basis] = collision_reconciled[:cost_basis]
              updates[:cost_basis_source] = collision_reconciled[:cost_basis_source]
            end

            # Adopt the row to this provider if it's currently unowned
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
  # @param activity_label [String, nil] Investment activity label (e.g., "Buy", "Sell", "Reinvestment")
  # @return [Entry] The created entry with trade
  def import_trade(security:, quantity:, price:, amount:, currency:, date:, name: nil, external_id: nil, source:, activity_label: nil)
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
        currency: currency,
        investment_activity_label: activity_label || (quantity > 0 ? "Buy" : "Sell")
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

  # Finds a pending transaction that likely matches a newly posted transaction
  # Used to reconcile pending→posted when SimpleFIN gives different IDs for the same transaction
  #
  # @param date [Date, String] Posted transaction date
  # @param amount [BigDecimal, Numeric] Transaction amount (must match exactly)
  # @param currency [String] Currency code
  # @param source [String] Provider name (e.g., "simplefin")
  # @param date_window [Integer] Days to search around the posted date (default: 8)
  # @return [Entry, nil] The pending entry or nil if not found
  def find_pending_transaction(date:, amount:, currency:, source:, date_window: 8)
    date = Date.parse(date.to_s) unless date.is_a?(Date)

    # Look for entries that:
    # 1. Same account (implicit via account.entries)
    # 2. Same source (simplefin)
    # 3. Same amount (exact match - this is the strongest signal)
    # 4. Same currency
    # 5. Date within window (pending can post days later)
    # 6. Is a Transaction (not Trade or Valuation)
    # 7. Has pending=true in transaction.extra["simplefin"]["pending"] or extra["plaid"]["pending"]
    candidates = account.entries
      .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
      .where(source: source)
      .where(amount: amount)
      .where(currency: currency)
      .where(date: (date - date_window.days)..date) # Pending must be ON or BEFORE posted date
      .where(<<~SQL.squish)
        (transactions.extra -> 'simplefin' ->> 'pending')::boolean = true
        OR (transactions.extra -> 'plaid' ->> 'pending')::boolean = true
        OR (transactions.extra -> 'lunchflow' ->> 'pending')::boolean = true
      SQL
      .order(date: :desc) # Prefer most recent pending transaction

    candidates.first
  end

  # Finds a pending transaction using fuzzy amount matching for tip adjustments
  # Used when exact amount matching fails - handles restaurant tips, adjusted authorizations, etc.
  #
  # IMPORTANT: Only returns a match if there's exactly ONE candidate to avoid false positives
  # with recurring merchant transactions (e.g., gas stations, coffee shops).
  #
  # @param date [Date, String] Posted transaction date
  # @param amount [BigDecimal, Numeric] Posted transaction amount (typically higher due to tip)
  # @param currency [String] Currency code
  # @param source [String] Provider name (e.g., "simplefin")
  # @param merchant_id [Integer, nil] Merchant ID for more accurate matching
  # @param name [String, nil] Transaction name for fuzzy name matching
  # @param date_window [Integer] Days to search backward from posted date (default: 3 for fuzzy)
  # @param amount_tolerance [Float] Maximum percentage difference allowed (default: 0.30 = 30%)
  # @return [Entry, nil] The pending entry or nil if not found/ambiguous
  def find_pending_transaction_fuzzy(date:, amount:, currency:, source:, merchant_id: nil, name: nil, date_window: 3, amount_tolerance: 0.30)
    date = Date.parse(date.to_s) unless date.is_a?(Date)
    amount = BigDecimal(amount.to_s)

    # Calculate amount bounds using ABS to handle both positive and negative amounts
    # Posted amount should be >= pending (tips add, not subtract)
    # Allow posted to be up to 30% higher than pending (covers typical tips)
    abs_amount = amount.abs
    min_pending_abs = abs_amount / (1 + amount_tolerance) # If posted is 100, pending could be as low as ~77
    max_pending_abs = abs_amount # Pending should not be higher than posted

    # Build base query for pending transactions
    # CRITICAL: Pending must be ON or BEFORE the posted date (authorization happens first)
    # Use tighter date window (3 days) - tips post quickly, not a week later
    # Use ABS() for amount comparison to handle negative amounts correctly
    candidates = account.entries
      .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
      .where(source: source)
      .where(currency: currency)
      .where(date: (date - date_window.days)..date) # Pending ON or BEFORE posted
      .where("ABS(entries.amount) BETWEEN ? AND ?", min_pending_abs, max_pending_abs)
      .where(<<~SQL.squish)
        (transactions.extra -> 'simplefin' ->> 'pending')::boolean = true
        OR (transactions.extra -> 'plaid' ->> 'pending')::boolean = true
        OR (transactions.extra -> 'lunchflow' ->> 'pending')::boolean = true
      SQL

    # If merchant_id is provided, prioritize matching by merchant
    if merchant_id.present?
      merchant_matches = candidates.where("transactions.merchant_id = ?", merchant_id).to_a
      # Only match if exactly ONE candidate to avoid false positives
      return merchant_matches.first if merchant_matches.size == 1
      if merchant_matches.size > 1
        Rails.logger.info("Skipping fuzzy pending match: #{merchant_matches.size} ambiguous merchant candidates for amount=#{amount} date=#{date}")
      end
    end

    # If name is provided, try fuzzy name matching as fallback
    if name.present?
      # Extract first few significant words for comparison
      name_words = name.downcase.gsub(/[^a-z0-9\s]/, "").split.first(3).join(" ")
      if name_words.present?
        name_matches = candidates.select do |c|
          c_name_words = c.name.downcase.gsub(/[^a-z0-9\s]/, "").split.first(3).join(" ")
          name_words == c_name_words
        end
        # Only match if exactly ONE candidate to avoid false positives
        return name_matches.first if name_matches.size == 1
        if name_matches.size > 1
          Rails.logger.info("Skipping fuzzy pending match: #{name_matches.size} ambiguous name candidates for '#{name_words}' amount=#{amount} date=#{date}")
        end
      end
    end

    # No merchant or name match, return nil (too risky to match on amount alone)
    # This prevents false positives when multiple pending transactions exist
    nil
  end

  # Finds a pending transaction with low confidence (>30% to 100% amount difference)
  # Used for large tip scenarios where normal fuzzy matching would miss
  # Creates a "review recommended" suggestion rather than "possible duplicate"
  #
  # @param date [Date, String] Posted transaction date
  # @param amount [BigDecimal, Numeric] Posted transaction amount
  # @param currency [String] Currency code
  # @param source [String] Provider name
  # @param merchant_id [Integer, nil] Merchant ID for matching
  # @param name [String, nil] Transaction name for matching
  # @param date_window [Integer] Days to search backward (default: 3)
  # @return [Entry, nil] The pending entry or nil if not found/ambiguous
  def find_pending_transaction_low_confidence(date:, amount:, currency:, source:, merchant_id: nil, name: nil, date_window: 3)
    date = Date.parse(date.to_s) unless date.is_a?(Date)
    amount = BigDecimal(amount.to_s)

    # Allow up to 100% difference (e.g., $50 pending → $100 posted with huge tip)
    # This is low confidence - requires strong name/merchant match
    # Use ABS to handle both positive and negative amounts correctly
    abs_amount = amount.abs
    min_pending_abs = abs_amount / 2.0 # Posted could be up to 2x pending
    max_pending_abs = abs_amount * 0.77 # Pending must be at least 30% less (to not overlap with fuzzy)

    # Build base query for pending transactions
    # Use ABS() for amount comparison to handle negative amounts correctly
    candidates = account.entries
      .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
      .where(source: source)
      .where(currency: currency)
      .where(date: (date - date_window.days)..date)
      .where("ABS(entries.amount) BETWEEN ? AND ?", min_pending_abs, max_pending_abs)
      .where(<<~SQL.squish)
        (transactions.extra -> 'simplefin' ->> 'pending')::boolean = true
        OR (transactions.extra -> 'plaid' ->> 'pending')::boolean = true
        OR (transactions.extra -> 'lunchflow' ->> 'pending')::boolean = true
      SQL

    # For low confidence, require BOTH merchant AND name match (stronger signal needed)
    if merchant_id.present? && name.present?
      name_words = name.downcase.gsub(/[^a-z0-9\s]/, "").split.first(3).join(" ")
      return nil if name_words.blank?

      merchant_matches = candidates.where("transactions.merchant_id = ?", merchant_id).to_a
      name_matches = merchant_matches.select do |c|
        c_name_words = c.name.downcase.gsub(/[^a-z0-9\s]/, "").split.first(3).join(" ")
        name_words == c_name_words
      end

      # Only match if exactly ONE candidate
      return name_matches.first if name_matches.size == 1
    end

    nil
  end

  # Stores a duplicate suggestion on a pending entry for user review
  # The suggestion is stored in the pending transaction's extra field
  #
  # @param pending_entry [Entry] The pending entry that may be a duplicate
  # @param posted_entry [Entry] The posted entry it may match
  # @param reason [String] Why this was flagged (e.g., "fuzzy_amount_match", "low_confidence_match")
  # @param posted_amount [BigDecimal] The posted transaction amount
  # @param confidence [String] Confidence level: "medium" (≤30% diff) or "low" (>30% diff)
  def store_duplicate_suggestion(pending_entry:, posted_entry:, reason:, posted_amount:, confidence: "medium")
    return unless pending_entry&.entryable.is_a?(Transaction)

    pending_transaction = pending_entry.entryable
    existing_extra = pending_transaction.extra || {}

    # Don't overwrite if already has a suggestion (keep first one found)
    return if existing_extra["potential_posted_match"].present?

    # Don't suggest if the posted entry is also still pending (pending→pending match)
    # Suggestions are only for pending→posted reconciliation
    posted_transaction = posted_entry.entryable
    return if posted_transaction.is_a?(Transaction) && posted_transaction.pending?

    pending_transaction.update!(
      extra: existing_extra.merge(
        "potential_posted_match" => {
          "entry_id" => posted_entry.id,
          "reason" => reason,
          "posted_amount" => posted_amount.to_s,
          "confidence" => confidence,
          "detected_at" => Date.current.to_s
        }
      )
    )
  end

  # Auto-detects investment activity label from transaction name and amount
  # Only detects extremely obvious cases to maintain high accuracy
  # Users can always manually adjust the label afterward
  #
  # @param name [String] Transaction name/description
  # @param amount [BigDecimal, Numeric] Transaction amount (positive or negative)
  # @return [String, nil] Detected activity label or nil if no pattern matches
  def detect_activity_label(name, amount)
    return nil if name.blank?

    name_lower = name.downcase.strip

    # Only detect the most obvious patterns - be conservative to avoid false positives
    # Users can manually adjust labels for edge cases
    case name_lower
    when /^dividend\b/, /\bdividend payment\b/, /\bqualified dividend\b/, /\bordinary dividend\b/
      "Dividend"
    when /^interest\b/, /\binterest income\b/, /\binterest payment\b/
      "Interest"
    when /^fee\b/, /\bmanagement fee\b/, /\badvisory fee\b/, /\btransaction fee\b/
      "Fee"
    when /\bemployer match\b/, /\bemployer contribution\b/
      "Contribution"
    when /\b401[k\(]/, /\bira contribution\b/, /\broth contribution\b/
      "Contribution"
    else
      nil # Let user categorize manually - default to nil for safety
    end
  end

  # Determines why an entry should be skipped during sync.
  # Returns nil if entry should NOT be skipped.
  #
  # @param entry [Entry] The entry to check
  # @return [String, nil] Skip reason or nil if entry can be synced
  def determine_skip_reason(entry)
    return "excluded" if entry.excluded?
    return "user_modified" if entry.user_modified?
    return "import_locked" if entry.import_locked?
    nil
  end

  # Records a skipped entry for stats collection.
  #
  # @param entry [Entry] The entry that was skipped
  # @param reason [String] Why it was skipped
  def record_skip(entry, reason)
    @skipped_entries << {
      id: entry.id,
      name: entry.name,
      reason: reason,
      external_id: entry.external_id,
      account_name: entry.account.name
    }
  end
end
