require "digest/md5"

class Provider::AccountData::Mercury < Provider::AccountData::Adapter
  include Provider::AccountData::Normalization

  DEFINITION = Provider::AccountData::Definition.new(
    key: "mercury", source: "mercury", credential_scope: "connection", capabilities: [ "transactions" ],
    fields: [ { name: "token", type: "text", secret: true }, { name: "base_url", type: "string", secret: false } ]
  )

  def self.definition
    DEFINITION
  end

  def self.editable_connection_credentials
    [ "token" ]
  end

  def self.account_setup_types
    %w[Depository]
  end

  # Legacy cache replacement only advances pending IDs to nonpending status.
  def self.transaction_status_policy
    "pending_to_posted"
  end

  def self.build(credentials:, settings:, context:)
    client = Provider::Mercury.new(
      credentials.with_indifferent_access.fetch(:token),
      base_url: settings.with_indifferent_access[:base_url].presence || "https://api.mercury.com/api/v1"
    )
    new(client: client, timezone: context.fetch(:timezone))
  end

  def initialize(client:, timezone:)
    super(client: client)
    @timezone = timezone
  end

  def self.initial_history_metadata_keys
    [ "mercury_initial_history_start" ]
  end

  # Cutover supplies each account's verified first-read bound. Explicit user
  # dates and completed checkpoints retain their normal runtime precedence.
  def initial_history_start(account:, observed_at:)
    metadata = account.fetch(:metadata, {})
    return super unless metadata.key?("mercury_initial_history_start")

    value = metadata.fetch("mercury_initial_history_start")
    unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      raise Provider::AccountData::InvalidResponse, "Invalid Mercury initial history date"
    end
    Date.iso8601(value)
  rescue ArgumentError, TypeError
    raise Provider::AccountData::InvalidResponse, "Invalid Mercury initial history date", cause: nil
  end

  def list_accounts(cursor: nil)
    result = checked_page(client.get_accounts_page(cursor: cursor))
    Provider::AccountData::Page.new(
      records: result[:items].map { |raw| normalize_account(raw) }, mode: "snapshot",
      next_cursor: result[:next_cursor], complete: result[:next_cursor].nil?,
      evidence: { "response" => result[:evidence] || { accounts: result[:items] } }
    )
  rescue ArgumentError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Mercury account page", cause: nil
  end

  def fetch_transactions(account:, cursor: nil, window: nil)
    scope = (window || {}).with_indifferent_access
    result = checked_page(client.get_account_transactions_page(
      account[:external_id], cursor: cursor, start_date: scope[:start], end_date: scope[:end]
    ))
    records = result[:items].filter_map { |raw| normalize_transaction(raw, account: account) }
    excluded_count = result[:items].size - records.size
    Provider::AccountData::Page.new(
      records: records, mode: "delta", next_cursor: result[:next_cursor], complete: result[:next_cursor].nil?,
      coverage: scope.to_h.merge("resource" => "transaction", "date_basis" => "provider_filter"),
      warnings: excluded_count.positive? ? [ { "code" => "failed_transactions_excluded", "count" => excluded_count } ] : [],
      evidence: { "response" => result[:evidence] || { transactions: result[:items] } }
    )
  rescue ArgumentError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Mercury transaction page", cause: nil
  end

  def normalize_account(raw)
    data = raw.with_indifferent_access
    balance = decimal(data[:currentBalance] || data[:current_balance])
    Ingestion::Record.account(
      external_id: data.fetch(:id), name: data[:nickname].presence || data[:name].presence || data[:legalBusinessName].presence,
      currency: "USD", account_type: data[:type], balance: balance, cash_balance: balance,
      available_balance: data[:availableBalance].nil? ? nil : decimal(data[:availableBalance]),
      metadata: {
        institution: { name: "Mercury", domain: "mercury.com", url: "https://mercury.com" },
        account_kind: data[:kind], account_status: data[:status],
        balance_policy: { debt_transform: "negate", debt_types: [ "CreditCard", "Loan" ], cash_balance: "balance" }
      }.compact,
      sensitive_details: {
        legal_business_name: data[:legalBusinessName], account_number: data[:accountNumber], routing_number: data[:routingNumber]
      }.compact
    )
  rescue ArgumentError, TypeError, NoMethodError, KeyError
    raise Provider::AccountData::InvalidResponse, "Invalid Mercury account", cause: nil
  end

  # Legacy Mercury JSON caches already lost source decimal precision. Reproduce
  # the former processor's Float#to_s conversion explicitly for migration parity;
  # the native transport and normalize_* entry points continue to reject Floats.
  def normalize_legacy_account(raw)
    data = raw.with_indifferent_access.deep_dup
    %i[currentBalance current_balance availableBalance].each do |field|
      data[field] = legacy_float_decimal(data[field]) if data.key?(field)
    end
    normalize_account(data)
  rescue ArgumentError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid legacy Mercury account", cause: nil
  end

  def normalize_legacy_transaction(raw, account:)
    data = raw.with_indifferent_access.deep_dup
    data[:amount] = legacy_float_decimal(data[:amount]) if data.key?(:amount)
    normalize_transaction(data, account: account)
  rescue ArgumentError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid legacy Mercury transaction", cause: nil
  end

  # Mercury reuses IDs when a pending item posts. Preserve that ID and explicitly
  # clear the pending flag. Failed records have never entered the existing ledger.
  def normalize_transaction(raw, account:)
    data = raw.with_indifferent_access
    if data[:accountId].present? && data[:accountId] != account[:external_id]
      raise ArgumentError, "Transaction ownership mismatch"
    end
    return nil if data[:status] == "failed"

    id = data.fetch(:id)
    raise ArgumentError unless id.is_a?(String) && id.present?
    pending = data[:status] == "pending"
    merchant_name = data[:counterpartyName].to_s.strip.presence
    merchant = merchant_name && { external_id: "mercury_merchant_#{Digest::MD5.hexdigest(merchant_name.downcase)}", name: merchant_name }
    extra = { "pending" => pending }
    extra["kind"] = data[:kind] if data[:kind].present?
    extra["counterparty_id"] = data[:counterpartyId] if data[:counterpartyId].present?
    notes = [ data[:note], data[:details] ].select(&:present?)
    Ingestion::Record.transaction(
      external_id: "mercury_#{id}", amount: -decimal(data.fetch(:amount)), currency: "USD",
      date: date_in_zone(data[:postedAt].presence || data[:createdAt].presence),
      name: data[:counterpartyNickname].presence || data[:counterpartyName].presence || data[:bankDescription].presence || "Unknown transaction",
      pending: pending,
      metadata: { merchant: merchant, notes: notes.any? ? notes.join(" - ") : nil, extra: { "mercury" => extra },
        transaction_status_policy: self.class.transaction_status_policy }
    )
  rescue ArgumentError, TypeError, NoMethodError, KeyError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Mercury transaction", cause: nil
  end

  private
    attr_reader :timezone

    def legacy_float_decimal(value)
      return value unless value.is_a?(Float)
      raise ArgumentError unless value.finite?
      BigDecimal(value.to_s)
    end
end
