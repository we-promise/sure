require "digest/md5"

class Provider::AccountData::Sophtron < Provider::AccountData::Adapter
  include Provider::AccountData::Normalization

  DEFINITION = Provider::AccountData::Definition.new(
    key: "sophtron", source: "sophtron", credential_scope: "connection", capabilities: [ "transactions" ],
    fields: [ { name: "user_id", type: "string", secret: true }, { name: "access_key", type: "text", secret: true },
      { name: "base_url", type: "string", secret: false }, { name: "user_institution_id", type: "string", secret: false } ]
  )

  def self.definition
    DEFINITION
  end

  def self.external_account_inputs
    { mutable: %w[metadata.source_details metadata.sync_policy.manual], frozen: [], inventory: "linked" }
  end

  def self.context_sources
    %i[connection_details external_accounts]
  end

  def self.build(credentials:, settings:, context:)
    credentials, settings = credentials.with_indifferent_access, settings.with_indifferent_access
    connection = context.fetch(:connection_details).with_indifferent_access
    legacy = connection.dig(:metadata, :source_details)
    legacy = legacy ? Provider::AccountData::MigrationValue.decode(legacy).with_indifferent_access : {}
    institution_id = connection[:external_id].presence || settings[:user_institution_id].presence || legacy.dig(:identity, :user_institution_id)
    client = Provider::Sophtron.new(credentials.fetch(:user_id), credentials.fetch(:access_key),
      base_url: settings[:base_url].presence || Provider::Sophtron::DEFAULT_BASE_URL)
    new(client: client, timezone: context.fetch(:timezone), user_institution_id: institution_id,
      observed_at: context.fetch(:observed_at), external_accounts: context.fetch(:external_accounts), manual_sync: settings[:manual_sync] == true,
      institution: { name: legacy.dig(:metadata, :institution_name), domain: legacy.dig(:metadata, :institution_domain),
        url: legacy.dig(:metadata, :institution_url) }.compact)
  end

  def initialize(client:, timezone:, user_institution_id:, observed_at:, external_accounts: [], manual_sync: false, institution: {})
    super(client: client)
    @timezone, @user_institution_id, @observed_at = timezone, normalized_id(user_institution_id), observed_at.to_time
    @external_accounts = external_accounts.map { |account| account.with_indifferent_access.deep_dup }
    @manual_sync, @institution = manual_sync, institution.deep_dup
  end

  def list_accounts(cursor: nil)
    result = checked_page(client.get_ingestion_accounts(@user_institution_id, cursor: cursor))
    raise ArgumentError unless result[:next_cursor].nil?
    Provider::AccountData::Page.new(records: result[:items].map { |row| normalize_account(row) },
      mode: "snapshot", complete: true, evidence: { "response" => result[:evidence] || result[:items] })
  rescue ArgumentError, TypeError, NoMethodError, KeyError
    raise Provider::AccountData::InvalidResponse, "Invalid Sophtron account inventory", cause: nil
  end

  def normalize_account(raw)
    data = raw.with_indifferent_access
    id = normalized_id(first_present(data, :AccountID, :account_id, :id))
    institution_id = first_present(data, :UserInstitutionID, :user_institution_id)
    raise ArgumentError if institution_id && institution_id != @user_institution_id
    existing = @external_accounts.find { |account| account[:external_id] == id }
    legacy = existing&.dig(:metadata, :source_details)
    legacy = legacy ? Provider::AccountData::MigrationValue.decode(legacy).with_indifferent_access : {}
    manual = @manual_sync || legacy.dig(:settings, :manual_sync) == true || existing&.dig(:metadata, :sync_policy, :manual) == true
    amount = first_present(data, :AccountBalance, :account_balance, :Balance, :balance)
    available = first_present(data, :"available-balance", :available_balance, :AvailableBalance)
    balance = decimal(amount.nil? ? available : amount)
    account_number = first_present(data, :AccountNumber, :account_number)
    mask = data[:account_number_mask].presence || (account_number.present? ? "****#{account_number.to_s.gsub(/\s+/, '').last(4)}" : nil)
    Ingestion::Record.account(external_id: id,
      name: first_present(data, :AccountName, :account_name, :name),
      currency: known_currency(first_present(data, :BalanceCurrency, :balance_currency, :Currency, :currency)) || "USD",
      account_type: first_present(data, :AccountType, :account_type, :type).presence || "unknown",
      balance: balance, cash_balance: balance, available_balance: available.nil? ? nil : decimal(available),
      sensitive_details: { account_number_mask: mask }.compact,
      metadata: { institution: @institution.merge(name: first_present(data, :InstitutionName, :institution_name) || @institution[:name], user_institution_id: @user_institution_id).compact,
        account_subtype: first_present(data, :AccountSubType, :account_sub_type, :SubType, :sub_type).presence || "unknown",
        account_status: first_present(data, :AccountStatus, :account_status, :Status, :status).presence || "active",
        sync_policy: { manual: manual, refresh_before_incremental: true },
        balance_policy: { debt_transform: "negate", debt_types: [ "CreditCard", "Loan" ], cash_balance: "balance" } })
  rescue ArgumentError, TypeError, NoMethodError, KeyError
    raise Provider::AccountData::InvalidResponse, "Invalid Sophtron account", cause: nil
  end

  def normalize_legacy_account(raw)
    data = raw.with_indifferent_access.deep_dup
    %i[AccountBalance account_balance Balance balance available_balance AvailableBalance].each do |field|
      data[field] = legacy_float_decimal(data[field]) if data.key?(field)
    end
    data[:"available-balance"] = legacy_float_decimal(data[:"available-balance"]) if data.key?(:"available-balance")
    normalize_account(data)
  rescue ArgumentError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid legacy Sophtron account", cause: nil
  end

  def fetch_transactions(account:, cursor: nil, window: nil)
    require_automatic_account!(account)
    scope = (window || {}).with_indifferent_access
    # The runtime provides the selected overlap. First loads default to 120 days
    # and all requests honor the existing three-year retention floor.
    today = @observed_at.in_time_zone(@timezone).to_date
    requested = scope[:start] && date_in_zone(scope[:start])
    configured = scope[:explicit_start] == true ? requested : nil
    boundary = scope[:checkpoint_covered_through] && date_in_zone(scope[:checkpoint_covered_through])
    start_date = if scope[:initial] == false && boundary
      [ boundary - 60, configured ].compact.max
    else
      configured || (scope.key?(:initial) ? today - 120 : requested || today - 120)
    end
    start_date = [ start_date, today.advance(years: -3) ].max
    end_date = scope[:end] ? date_in_zone(scope[:end]) : @observed_at.in_time_zone(@timezone).to_date + 1
    result = checked_page(client.get_ingestion_transactions(account[:external_id], start_date: start_date, end_date: end_date, cursor: cursor))
    raise ArgumentError unless result[:next_cursor].nil?
    Provider::AccountData::Page.new(records: result[:items].map { |raw| normalize_transaction(raw, account: account) }, complete: true, mode: "delta",
      coverage: { "start" => start_date.in_time_zone(@timezone).iso8601, "end" => end_date.in_time_zone(@timezone).end_of_day.iso8601,
        "date_basis" => "transaction_date", "pending_absence_authoritative" => false },
      evidence: { "response" => result[:evidence] || result[:items] })
  rescue ArgumentError, TypeError, NoMethodError, KeyError
    raise Provider::AccountData::InvalidResponse, "Invalid Sophtron transaction response", cause: nil
  end

  def fetch_balance(account:, cursor: nil, window: nil)
    require_automatic_account!(account)
    super
  end

  def normalize_transaction(raw, account:)
    data = raw.with_indifferent_access
    owner = first_present(data, :AccountID, :account_id, :accountId)
    raise ArgumentError if owner && owner.to_s != account[:external_id]
    id = normalized_id(first_present(data, :TransactionID, :TransactionId, :transaction_id, :transactionId, :ID, :id))
    description = first_present(data, :Description, :description)
    label = first_present(data, :Merchant, :merchant).presence || extract_merchant(description).presence
    merchant_name = label.to_s.strip.presence
    # Sophtron's previous importer treats transactions as immutable and posted,
    # regardless of its descriptive Status field. Keep that ledger contract.
    Ingestion::Record.transaction(external_id: "sophtron_#{id}", name: label || I18n.t("sophtron_items.sophtron_entry.processor.unknown_transaction"),
      amount: -decimal(first_present(data, :Amount, :amount)),
      currency: known_currency(first_present(data, :Currency, :currency).presence || "USD") || account[:currency] || "USD",
      date: date_in_zone(first_present(data, :TransactionDate, :transaction_date, :Date, :date)), pending: false,
      metadata: { notes: description.presence, update_policy: "insert_only",
        merchant: merchant_name && { external_id: "sophtron_merchant_#{Digest::MD5.hexdigest(merchant_name.downcase)}", name: merchant_name } })
  rescue ArgumentError, TypeError, NoMethodError, KeyError
    raise Provider::AccountData::InvalidResponse, "Invalid Sophtron transaction", cause: nil
  end

  def normalize_legacy_transaction(raw, account:)
    data = raw.with_indifferent_access.deep_dup
    %i[Amount amount].each { |field| data[field] = legacy_float_decimal(data[field]) if data.key?(field) }
    normalize_transaction(data, account: account)
  rescue ArgumentError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid legacy Sophtron transaction", cause: nil
  end

  private
    def require_automatic_account!(account)
      manual = (account[:metadata] || {}).with_indifferent_access.dig(:sync_policy, :manual)
      if @manual_sync || manual == true
        raise Provider::AccountData::UnsupportedCapability, "Sophtron account requires the manual refresh workflow"
      end
    end

    def first_present(data, *keys)
      keys.each { |key| return data[key] if data[key].present? }
      nil
    end

    def legacy_float_decimal(value)
      return value unless value.is_a?(Float)
      raise ArgumentError unless value.finite?
      BigDecimal(value.to_s)
    end

    def extract_merchant(line)
      line = line.to_s.strip
      return nil if line.empty?
      case line
      when /INSUFFICIENT FUNDS FEE/i then "Bank Fee: Insufficient Funds"
      when /OVERDRAFT PROTECTION/i then "Bank Transfer: Overdraft Protection"
      when /AUTO PAY WF HOME MTG/i then "Wells Fargo Home Mortgage"
      when /PAYDAY LOAN/i then "Payday Loan"
      when /CHECKCARD \d{4}\s+(.+?)(?=\s{2,}|x{3,}|\s+\S+\s+[A-Z]{2}\b)/i then Regexp.last_match(1).strip
      when /^(.+?)(?=\s+\d{2}\/\d{2}|\s+#)/ then Regexp.last_match(1).strip.gsub(/\s+POS$/i, "").strip
      else line[0..25].strip
      end
    end
end
