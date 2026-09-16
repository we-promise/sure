require "base64"
require "digest"
require "json"

class Provider::AccountData::EnableBanking < Provider::AccountData::Adapter
  include Provider::AccountData::Normalization
  include TransactionNormalization

  MAX_PAGES = 100
  MAX_SEEN_TRANSACTIONS = 20_000
  BALANCE_TYPES = %w[CLBD closingBooked ITBD interimBooked XPCD expected CLAV closingAvailable ITAV interimAvailable].freeze

  DEFINITION = Provider::AccountData::Definition.new(
    key: "enable_banking", source: "enable_banking", credential_scope: "application", capabilities: [ "transactions" ],
    fields: [ { name: "application_id", type: "string", secret: true },
      { name: "client_certificate", type: "text", secret: true }, { name: "country_code", type: "string", secret: false } ]
  )

  def self.definition
    DEFINITION
  end

  def self.external_account_inputs
    { mutable: %w[currency metadata.source_details metadata.account_settings sensitive_details.identification_hashes], frozen: %w[name account_type], inventory: "linked" }
  end

  def self.frozen_context_sources
    [ :known_merchant_names ]
  end

  def self.initial_history_metadata_keys
    [ "enable_banking_initial_history_start" ]
  end

  def initial_history_start(account:, observed_at:)
    metadata = account.fetch(:metadata, {})
    return super unless metadata.key?("enable_banking_initial_history_start")

    value = metadata.fetch("enable_banking_initial_history_start")
    return nil if value.nil? # Explicit cutover request for all accessible history.
    unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      raise Provider::AccountData::InvalidResponse, "Invalid Enable Banking initial history date"
    end
    Date.iso8601(value)
  rescue ArgumentError, TypeError
    raise Provider::AccountData::InvalidResponse, "Invalid Enable Banking initial history date", cause: nil
  end

  def self.context_sources
    %i[authorizations external_accounts known_merchant_names]
  end

  def self.build(credentials:, settings:, context:)
    credentials = credentials.with_indifferent_access
    new(client: Provider::EnableBanking.new(application_id: credentials.fetch(:application_id),
      client_certificate: credentials.fetch(:client_certificate)), timezone: context.fetch(:timezone),
      authorizations: context.fetch(:authorizations), external_accounts: context.fetch(:external_accounts),
      known_merchant_names: context.fetch(:known_merchant_names), observed_at: context.fetch(:observed_at),
      include_pending: context.fetch(:pending_preference), country_code: settings.with_indifferent_access[:country_code])
  end

  def initialize(client:, timezone:, authorizations:, external_accounts:, known_merchant_names:, observed_at:, include_pending:, country_code: nil)
    super(client: client)
    raise ArgumentError unless authorizations.is_a?(Array) && external_accounts.is_a?(Array) &&
      known_merchant_names.is_a?(Array) && known_merchant_names.all? { |name| name.is_a?(String) } &&
      [ true, false ].include?(include_pending)
    @timezone, @observed_at, @include_pending, @country_code = timezone, observed_at.to_time, include_pending, country_code
    @authorizations = authorizations.map { |value| value.with_indifferent_access.deep_dup }
    @external_accounts = external_accounts.map { |value| value.with_indifferent_access.deep_dup }
    @known_merchant_names = known_merchant_names.map(&:dup).freeze
  end

  # One session inventory per page. Session credentials never enter cursor or
  # account metadata. An unavailable consent leaves the full inventory incomplete
  # while allowing other institutions and already-linked accounts to continue.
  def list_accounts(cursor: nil)
    state = decode_cursor(cursor, "accounts") || { "index" => 0, "failed" => false }
    index = state.fetch("index")
    raise ArgumentError unless index.is_a?(Integer) && index >= 0 && index < @authorizations.size
    authorization = @authorizations.fetch(index)
    records, warnings, evidence = [], [], {}
    begin
      require_usable_authorization!(authorization)
      session = client.get_ingestion_session(session_id: authorization.fetch(:credentials).fetch(:session_id)).with_indifferent_access
      evidence["session"] = session
      if session[:status].present? && session[:status] != "AUTHORIZED"
        raise AuthorizationUnavailable
      end
      if session.dig(:access, :valid_until).present? && Time.iso8601(session.dig(:access, :valid_until)) <= @observed_at
        raise AuthorizationUnavailable
      end
      accounts = session.fetch(:accounts)
      raise ArgumentError unless accounts.is_a?(Array) && accounts.size <= 2000
      details = Array(session[:accounts_data]).map { |row| row.with_indifferent_access }
      evidence["account_details"] = []
      accounts.each do |raw|
        data = raw.is_a?(String) ? { uid: raw }.with_indifferent_access : raw.with_indifferent_access
        uid = normalized_id(data[:uid])
        supplemental = details.find { |row| row[:uid] == uid } || {}
        # GET /sessions may contain UID strings only. Details are independent
        # reads; never infer a zero balance from this inventory response.
        account_details = client.get_ingestion_account_details(account_id: uid, psu_headers: psu_headers(authorization))
        evidence["account_details"] << account_details
        account_details = account_details.with_indifferent_access
        raise ArgumentError if account_details[:uid].present? && account_details[:uid] != uid
        merged = account_details.merge(supplemental).merge(data)
        records << normalize_account(merged, authorization: authorization)
      end
    rescue AuthorizationUnavailable
      state["failed"] = true
      warnings << { "code" => "authorization_requires_update", "authorization_id" => authorization[:id] }
    rescue Provider::EnableBanking::EnableBankingError => error
      state["failed"] = true
      # A session-level 401/404 invalidates only this institution's consent. An
      # account-level 401/404 does not invalidate the application or the session.
      session_failure = !evidence.key?("session") && %i[unauthorized not_found].include?(error.error_type)
      warnings << { "code" => session_failure ? "authorization_requires_update" : "authorization_inventory_unavailable",
        "authorization_id" => authorization[:id], "error_type" => error.error_type.to_s }
      evidence["error"] = error.response_data if error.response_data.is_a?(Hash)
    end
    next_cursor = index + 1 < @authorizations.size ? encode_cursor("accounts", state.merge("index" => index + 1)) : nil
    Provider::AccountData::Page.new(records: records, complete: next_cursor.nil? && !state["failed"],
      next_cursor: next_cursor, mode: "snapshot", warnings: warnings,
      evidence: evidence.merge("authorization_id" => authorization[:id]))
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Enable Banking account inventory", cause: nil
  end

  def normalize_account(raw, authorization: @authorizations.first, existing: nil)
    data = raw.with_indifferent_access
    uid = normalized_id(data[:uid])
    aliases = [ data[:identification_hash], *Array(data[:identification_hashes]), uid ].compact
    existing ||= matching_account(aliases, authorization)
    identity = existing&.dig(:external_id).presence || data[:identification_hash].presence || uid
    iban = account_iban(data)
    legacy = legacy_details(existing)
    account_settings = legacy.fetch(:settings, {}).merge((existing&.dig(:metadata, :account_settings) || {}))
    limit_value = data[:credit_limit].presence || legacy.dig(:attributes, :credit_limit)
    limit_value = limit_value[:amount] || limit_value["amount"] if limit_value.is_a?(Hash)
    limit = limit_value.nil? ? nil : decimal(limit_value)
    policy = { debt_transform: "absolute", debt_types: [ "CreditCard", "Loan" ], cash_balance: "balance", current_anchor: true,
      credit_card_mode: account_settings[:treat_balance_as_available_credit] == true ? "available_credit" : "outstanding_debt",
      credit_limit: limit&.to_s("F") }
    Ingestion::Record.account(external_id: identity,
      name: data[:name].presence || existing&.dig(:name).presence || (iban.present? ? "Account ...#{iban[-4..]}" : "Enable Banking Account"),
      currency: known_currency(data[:currency]) || existing&.dig(:currency) || "EUR",
      account_type: data[:cash_account_type].presence || data[:account_type].presence || existing&.dig(:account_type),
      metadata: { balance_provided: false, authorization_id: authorization.fetch(:id),
        institution: authorization[:institution_metadata] || {}, product: data[:product], balance_policy: policy,
        account_settings: account_settings },
      sensitive_details: { api_account_id: uid, identification_hashes: aliases.uniq, iban: iban }.compact)
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Enable Banking account", cause: nil
  end

  def normalize_legacy_account(raw, **options)
    data = raw.with_indifferent_access.deep_dup
    data[:credit_limit] = legacy_float_decimal(data[:credit_limit]) if data.key?(:credit_limit)
    normalize_account(data, **options)
  rescue ArgumentError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid legacy Enable Banking account", cause: nil
  end

  def fetch_balance(account:, cursor: nil, window: nil)
    raise ArgumentError unless cursor.nil?
    authorization = authorization_for(account)
    response = client.get_ingestion_account_balances(account_id: api_account_id(account), psu_headers: psu_headers(authorization))
    normalize_balance(response, account: account)
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Enable Banking balance response", cause: nil
  end

  def normalize_balance(raw, account:)
    data = raw.with_indifferent_access
    balances = data.fetch(:balances)
    raise ArgumentError unless balances.is_a?(Array) && balances.all? { |row| row.is_a?(Hash) }
    by_type = balances.map(&:with_indifferent_access).index_by { |balance| balance[:balance_type].to_s.delete("_-").downcase }
    selected = BALANCE_TYPES.filter_map { |type| by_type[type.downcase] }.first || balances.first&.with_indifferent_access
    amount = selected&.dig(:balance_amount, :amount) || selected&.dig(:amount)
    available = amount.present?
    attrs = account.attributes.merge(balance: nil, cash_balance: nil,
      metadata: (account[:metadata] || {}).with_indifferent_access.merge(balance_provided: true))
    if available
      amount = decimal(amount)
      amount = -amount if selected[:credit_debit_indicator].to_s.upcase == "DBIT"
      attrs.merge!(balance: amount, cash_balance: amount,
        currency: known_currency(selected.dig(:balance_amount, :currency) || selected[:currency]) || account[:currency] || "EUR")
    end
    Provider::AccountData::Page.new(records: [ Ingestion::Record.account(**attrs) ], mode: "snapshot", complete: true,
      warnings: available ? [] : [ { "code" => "balance_unavailable" } ], evidence: { "response" => raw })
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Enable Banking balance", cause: nil
  end

  def normalize_legacy_balance(raw, account:)
    data = raw.with_indifferent_access.deep_dup
    Array(data[:balances]).each do |balance|
      balance[:amount] = legacy_float_decimal(balance[:amount]) if balance.key?(:amount)
      if balance[:balance_amount].is_a?(Hash)
        balance[:balance_amount][:amount] = legacy_float_decimal(balance[:balance_amount][:amount])
      end
    end
    normalize_balance(data, account: account)
  rescue ArgumentError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid legacy Enable Banking balance", cause: nil
  end

  def fetch_transactions(account:, cursor: nil, window: nil)
    authorization = authorization_for(account)
    state = decode_cursor(cursor, "transactions") || transaction_state(account, window)
    raise ArgumentError unless state["account"] == Digest::SHA256.hexdigest(account[:external_id])
    raise Provider::AccountData::IncompletePage, "Enable Banking pagination limit exceeded" if state.fetch("pages") >= MAX_PAGES
    phase = state.fetch("phase")
    raise ArgumentError unless %w[BOOK PDNG].include?(phase)
    result = checked_page(client.get_ingestion_transactions_page(account_id: api_account_id(account),
      date_from: state["date_from"] && Date.iso8601(state["date_from"]), date_to: state["date_to"] && Date.iso8601(state["date_to"]),
      continuation_key: state["continuation"], transaction_status: phase, psu_headers: psu_headers(authorization), reference_date: @observed_at.to_date))
    state["history_narrowed"] = true if result[:narrowed_window] == true
    history_complete = state["history_narrowed"] != true
    state["date_from"] = result[:date_from]&.iso8601
    state["date_to"] = result[:date_to]&.iso8601
    state["pages"] += 1
    rows = result[:items].map(&:with_indifferent_access)
    records = normalize_transaction_page(rows, account: account, state: state)
    next_api_cursor = result[:next_cursor]
    if next_api_cursor
      digest = Digest::SHA256.hexdigest(next_api_cursor)
      raise Provider::AccountData::IncompletePage, "Enable Banking continuation repeated" if state["cursors"].include?(digest)
      state["cursors"] << digest
      state["continuation"] = next_api_cursor
    elsif phase == "BOOK" && @include_pending
      state.merge!("phase" => "PDNG", "continuation" => nil, "cursors" => [], "pages" => 0)
    else
      state = nil
    end
    warnings = result[:narrowed_window] ? [ { "code" => "transaction_window_narrowed" } ] : []
    transaction_page(records, state, result, authorization, warnings: warnings, history_complete: history_complete)
  rescue Provider::EnableBanking::EnableBankingError => error
    # Pending unsupported is an explicit partial capability. A failed continuation
    # or a narrowed-period error must remain incomplete and retain its checkpoint.
    if state && state["phase"] == "PDNG" && state["pages"].zero? &&
        %i[bad_request validation_error].include?(error.error_type) && !error.wrong_transactions_period?
      transaction_page([], nil, { date_from: state["date_from"] && Date.iso8601(state["date_from"]),
        date_to: state["date_to"] && Date.iso8601(state["date_to"]), evidence: error.response_data || {} }, authorization,
        warnings: [ { "code" => "pending_unsupported", "error_type" => error.error_type.to_s } ],
        history_complete: state["history_narrowed"] != true)
    else
      raise
    end
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Enable Banking transaction page", cause: nil
  end

  private
    class AuthorizationUnavailable < Provider::AccountData::Error; end

    def require_usable_authorization!(authorization)
      raise AuthorizationUnavailable unless authorization[:status] == "active" && authorization.dig(:credentials, :session_id).present?
      if authorization[:expires_at].present? && Time.iso8601(authorization[:expires_at]) <= @observed_at
        raise AuthorizationUnavailable
      end
    end

    def authorization_for(account)
      id = (account[:metadata] || {}).with_indifferent_access[:authorization_id]
      authorization = @authorizations.find { |grant| grant[:id] == id }
      raise AuthorizationUnavailable unless authorization
      require_usable_authorization!(authorization)
      authorization
    end

    def api_account_id(account)
      normalized_id((account[:sensitive_details] || {}).with_indifferent_access[:api_account_id])
    end

    def psu_headers(authorization)
      required = Array(authorization.dig(:metadata, :grant_settings, :aspsp_required_psu_headers)).map(&:downcase)
      ip = authorization.dig(:credentials, :last_psu_ip)
      required.any? && required.all? { |header| header == "psu-ip-address" } && ip.present? ? { "Psu-Ip-Address" => ip } : {}
    end

    def matching_account(aliases, authorization)
      matches = @external_accounts.select do |account|
        next false unless Array(account[:authorization_ids]).include?(authorization[:id])
        legacy = legacy_details(account)
        known = [ account[:external_id], *Array(account.dig(:sensitive_details, :identification_hashes)),
          legacy.dig(:identity, :uid), legacy.dig(:identity, :account_id), *Array(legacy.dig(:identity, :identification_hashes)) ].compact
        (known & aliases).any?
      end
      raise ArgumentError, "Ambiguous account identity" if matches.many?
      matches.first
    end

    def legacy_details(account)
      encoded = account&.dig(:metadata, :source_details)
      encoded ? Provider::AccountData::MigrationValue.decode(encoded).with_indifferent_access : {}.with_indifferent_access
    end

    def account_iban(data)
      identification = data[:account_id]
      identification = identification.find { |item| item.is_a?(Hash) && (item[:iban] || item["iban"]).present? } if identification.is_a?(Array)
      identification.is_a?(Hash) ? identification[:iban] || identification["iban"] || data[:iban] : data[:iban]
    end

    def transaction_state(account, window)
      scope = (window || {}).with_indifferent_access
      { "account" => Digest::SHA256.hexdigest(account[:external_id]), "phase" => "BOOK", "pages" => 0,
        "date_from" => scope[:start] && date_in_zone(scope[:start]).iso8601,
        "date_to" => scope[:end] && date_in_zone(scope[:end]).iso8601,
        "continuation" => nil, "cursors" => [], "contents" => [], "book_ids" => [], "book_refs" => [] }
    end

    def normalize_transaction_page(rows, account:, state:)
      rows.filter_map do |data|
        pending = state["phase"] == "PDNG" || data[:status] == "PDNG" || data[:_pending] == true
        next if pending && !@include_pending
        id = transaction_external_id(data)
        id_hash = Digest::SHA256.hexdigest(id)
        ref_hash = data[:entry_reference].present? ? Digest::SHA256.hexdigest(data[:entry_reference]) : nil
        if pending && (state["book_ids"].include?(id_hash) || (ref_hash && state["book_refs"].include?(ref_hash)))
          next
        end
        content = transaction_content_digest(data)
        # A BOOK observation may replace a pending one with identical content.
        # Different transaction IDs remain distinct, even for identical purchases.
        content_key = "#{pending ? 'pending' : 'booked'}:#{content}"
        next if state["contents"].include?(content_key)
        state["contents"] << content_key
        unless pending
          state["book_ids"] << id_hash
          state["book_refs"] << ref_hash if ref_hash
        end
        raise Provider::AccountData::IncompletePage, "Enable Banking transaction limit exceeded" if state["contents"].size > MAX_SEEN_TRANSACTIONS
        record = normalize_transaction(data.merge(_pending: pending), account: account)
        next if state["date_from"] && record[:date] < Date.iso8601(state["date_from"])
        record
      end
    end

    def transaction_page(records, state, result, authorization, warnings: [], history_complete: true)
      Provider::AccountData::Page.new(records: records, mode: "delta", complete: state.nil?,
        next_cursor: state && encode_cursor("transactions", state), warnings: warnings,
        coverage: { "start" => result[:date_from]&.in_time_zone(@timezone)&.iso8601,
          "end" => result[:date_to]&.in_time_zone(@timezone)&.end_of_day&.iso8601,
          "date_basis" => "booking_date", "pending_absence_authoritative" => false,
          "history_complete" => history_complete }.compact,
        evidence: { "response" => result[:evidence] || result[:items], "authorization_id" => authorization[:id],
          "normalization_context" => { "known_merchant_names" => @known_merchant_names, "include_pending" => @include_pending } })
    end

    def encode_cursor(operation, state)
      Base64.strict_encode64(JSON.generate({ "version" => 1, "operation" => operation, "state" => state }))
    end

    def decode_cursor(cursor, operation)
      return nil if cursor.nil?
      raise ArgumentError unless cursor.is_a?(String) && cursor.bytesize <= 6_000_000
      data = JSON.parse(Base64.strict_decode64(cursor))
      raise ArgumentError unless data["version"] == 1 && data["operation"] == operation && data["state"].is_a?(Hash)
      data["state"]
    end
end
