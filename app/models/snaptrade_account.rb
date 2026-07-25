class SnaptradeAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable
  include SnaptradeAccount::DataHelpers

  # Encrypt raw payloads if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
    encrypts :raw_holdings_payload
    encrypts :raw_activities_payload
    encrypts :raw_balances_payload
  end

  belongs_to :snaptrade_item

  # Association through account_providers for linking to Sure accounts
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true
  validates :snaptrade_account_id, uniqueness: { scope: :snaptrade_item_id, allow_nil: true }

  # Enqueue cleanup job after destruction to avoid blocking transaction with API call
  after_destroy :enqueue_connection_cleanup

  # Helper to get the linked Sure account
  def current_account
    linked_account
  end

  # Ensure there is an AccountProvider link for this SnapTrade account and the given Account.
  # Safe and idempotent; returns the AccountProvider or nil if no account is provided.
  def ensure_account_provider!(account = nil)
    # If account_provider already exists, update it if needed
    if account_provider.present?
      account_provider.update!(account: account) if account && account_provider.account_id != account.id
      return account_provider
    end

    # Need an account to create the provider
    acct = account || current_account
    return nil unless acct

    provider = AccountProvider
      .find_or_initialize_by(provider_type: "SnaptradeAccount", provider_id: id)
      .tap do |p|
        p.account = acct
        p.save!
      end

    # Reload the association so future accesses don't return stale/nil value
    reload_account_provider

    provider
  rescue => e
    Rails.logger.warn("SnaptradeAccount##{id}: failed to ensure AccountProvider link: #{e.class} - #{e.message}")
    nil
  end

  # Import account data from SnapTrade API response
  # Expected JSON structure:
  # {
  #   "id": "uuid",
  #   "brokerage_authorization": "uuid",  # just a string, not an object
  #   "name": "Robinhood Individual",
  #   "number": "123456",
  #   "institution_name": "Robinhood",
  #   "balance": { "total": { "amount": 1000.00, "currency": "USD" } },
  #   "meta": { "type": "INDIVIDUAL", "institution_name": "Robinhood" }
  # }
  def upsert_from_snaptrade!(account_data)
    # Deep convert SDK objects to hashes - .to_h only does top level,
    # so we use JSON round-trip to get nested objects as hashes too
    data = sdk_object_to_hash(account_data)
    data = data.with_indifferent_access

    # Extract meta data
    meta_data = (data[:meta] || {}).with_indifferent_access

    # Extract balance data - currency is nested in balance.total
    balance_data = (data[:balance] || {}).with_indifferent_access
    total_balance = (balance_data[:total] || {}).with_indifferent_access

    # Institution name can be at top level or in meta
    institution_name = data[:institution_name] || meta_data[:institution_name]

    # brokerage_authorization is just a string ID, not an object
    auth_id = data[:brokerage_authorization]
    auth_id = auth_id[:id] if auth_id.is_a?(Hash) # handle both formats

    update!(
      snaptrade_account_id: data[:id],
      snaptrade_authorization_id: auth_id,
      account_number: data[:number],
      name: data[:name] || "#{institution_name} Account",
      brokerage_name: institution_name,
      currency: extract_currency_code(total_balance[:currency]) || "USD",
      account_type: meta_data[:type] || data[:raw_type],
      account_status: data[:status],
      current_balance: total_balance[:amount],
      institution_metadata: {
        name: institution_name,
        sync_status: data[:sync_status],
        portfolio_group: data[:portfolio_group]
      }.compact,
      raw_payload: data
    )
  end

  # Store holdings data from SnapTrade API
  def upsert_holdings_snapshot!(holdings_data)
    update!(
      raw_holdings_payload: holdings_data,
      last_holdings_sync: Time.current
    )
  end

  # Store activities data from SnapTrade API
  def upsert_activities_snapshot!(activities_data)
    update!(
      raw_activities_payload: activities_data,
      last_activities_sync: Time.current
    )
  end

  # Store balances data
  # NOTE: This only updates cash_balance, NOT current_balance.
  # current_balance represents total account value (holdings + cash)
  # and is set by upsert_from_snaptrade! from the balance.total field.
  def upsert_balances!(balances_data)
    # Deep convert each balance entry to ensure we have hashes
    data = Array(balances_data).map { |b| sdk_object_to_hash(b).with_indifferent_access }

    Rails.logger.info "SnaptradeAccount##{id} upsert_balances! - raw data: #{data.inspect}"

    # The primary entry (account currency → USD → first) stays in cash_balance;
    # the full set is persisted so the processor can surface non-primary-currency
    # cash as holdings (issue #1809).
    cash_entry = primary_cash_entry(data)

    cash_value = cash_entry ? cash_entry[:cash] : cash_balance
    Rails.logger.info "SnaptradeAccount##{id} upsert_balances! - setting cash_balance=#{cash_value}, persisting #{data.size} entrie(s)"

    # Only update cash_balance, preserve current_balance (total account value)
    update!(cash_balance: cash_value, raw_balances_payload: data)
  end

  # Cash entries from the last balances snapshot that are NOT the one stored in
  # cash_balance. The primary entry (account currency → USD → first) lives in
  # cash_balance; the rest are surfaced as synthetic cash holdings so
  # multi-currency cash isn't discarded (issue #1809). Excludes the actual
  # primary currency — including the USD fallback — to avoid double-counting.
  def non_primary_cash_entries
    entries = normalized_balance_entries
    primary_code = primary_cash_entry(entries)&.dig(:currency, :code)

    entries.filter_map do |e|
      code = e.dig(:currency, :code)
      next if code.blank? || code == primary_code
      amount = e[:cash]
      next if amount.blank?
      { currency: code, amount: amount }
    end
  end

  # Currency of the amount stored in cash_balance. upsert_balances! falls back
  # to a USD (or first) balance entry when there is no entry in the account
  # currency, so the stored cash is not guaranteed to be denominated in
  # `currency` — cash adjustments must use this instead.
  def primary_cash_currency
    primary_cash_entry(normalized_balance_entries)&.dig(:currency, :code) || currency
  end

  # Total value of positions SnapTrade flags as `cash_equivalent` (usually
  # money market / sweep funds such as Fidelity's SPAXX) held in the given
  # currency. Per SnapTrade's docs, these positions are ALSO included in the
  # balances endpoint's `cash` figure, so cash figures must have this value
  # removed to avoid double counting the same money. The positions themselves
  # are still imported as holdings by SnaptradeAccount::HoldingsProcessor.
  def cash_equivalent_position_value(currency_code = currency)
    Array(raw_holdings_payload).sum(BigDecimal("0")) do |holding|
      data = holding.is_a?(Hash) ? holding.with_indifferent_access : {}
      next BigDecimal("0") unless data[:cash_equivalent] == true

      # Positions without currency metadata deliberately fall back to the
      # ACCOUNT currency (not currency_code): that's where HoldingsProcessor
      # books such a position as a holding, so it must be subtracted from that
      # same bucket — using currency_code here would subtract the position
      # from every caller's currency bucket.
      position_currency = extract_currency(data, extract_symbol_data(data), currency)
      next BigDecimal("0") unless position_currency == currency_code

      units = parse_decimal(data[:units]) || BigDecimal("0")
      price = parse_decimal(data[:price]) || BigDecimal("0")

      units * price
    end
  end

  # Get the SnapTrade provider instance via the parent item
  def snaptrade_provider
    snaptrade_item.snaptrade_provider
  end

  private

    def normalized_balance_entries
      Array(raw_balances_payload).map do |entry|
        entry.respond_to?(:with_indifferent_access) ? entry.with_indifferent_access : {}
      end
    end

    # Selects the primary cash entry from a list of indifferent-access balance
    # hashes: account currency first, then USD, then the first entry. Shared by
    # upsert_balances!, non_primary_cash_entries, and primary_cash_currency so
    # they stay in sync.
    def primary_cash_entry(entries)
      entries.find { |b| b.dig(:currency, :code) == currency } ||
        entries.find { |b| b.dig(:currency, :code) == "USD" } ||
        entries.first
    end

    # Enqueue a background job to clean up the SnapTrade connection
    # This runs asynchronously after the record is destroyed to avoid
    # blocking the DB transaction with an external API call
    def enqueue_connection_cleanup
      return unless snaptrade_authorization_id.present?

      SnaptradeConnectionCleanupJob.perform_later(
        snaptrade_item_id: snaptrade_item_id,
        authorization_id: snaptrade_authorization_id,
        account_id: id
      )
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for SnapTrade account #{id}, defaulting to USD")
    end

    # Extract currency code from either a string or a currency object (hash with :code key)
    # SnapTrade API may return currency as either format depending on the endpoint
    def extract_currency_code(currency_value)
      return nil if currency_value.blank?

      if currency_value.is_a?(Hash)
        # Currency object: { code: "USD", id: "..." }
        currency_value[:code] || currency_value["code"]
      else
        # String: "USD"
        parse_currency(currency_value)
      end
    end
end
