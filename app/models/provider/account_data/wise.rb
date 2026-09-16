require "base64"
require "json"
require "digest/sha2"

class Provider::AccountData::Wise < Provider::AccountData::Adapter
  include Provider::AccountData::Normalization

  ACTIVITY_TYPES = %w[INTERBALANCE BALANCE_CASHBACK BALANCE_ASSET_FEE].freeze
  INCOMING_STATUSES = %w[incoming_payment_waiting incoming_payment_received funds_credited credited].freeze
  STATEMENT_WINDOW_DAYS = 30
  DEFINITION = Provider::AccountData::Definition.new(
    key: "wise", source: "wise", credential_scope: "connection", capabilities: [ "transactions" ],
    fields: [ { name: "token", type: "text", secret: true }, { name: "sca_private_key", type: "text", secret: true },
      { name: "profile_id", type: "string", secret: false }, { name: "import_all_history", type: "boolean", secret: false, default: false } ]
  )

  def self.definition
    DEFINITION
  end

  def self.initial_history_metadata_keys
    [ "creation_time" ]
  end

  def self.context_sources
    [ :wise_account_history ]
  end

  def self.frozen_context_sources
    [ :wise_account_history ]
  end

  def self.external_account_inputs
    { mutable: [ "currency" ], frozen: [], inventory: "linked" }
  end

  # Activation still requires coverage acceptance and lifecycle/cutover review.
  def self.native_ready?
    false
  end

  def self.build(credentials:, settings:, context:)
    credentials = credentials.with_indifferent_access
    settings = settings.with_indifferent_access
    base_url = context[:environment] == "sandbox" ? Provider::Wise::SANDBOX_BASE_URL : Provider::Wise::LIVE_BASE_URL
    new(client: Provider::Wise.new(credentials.fetch(:token), base_url: base_url, sca_private_key: credentials[:sca_private_key]),
      profile_id: settings.fetch(:profile_id), timezone: context.fetch(:timezone),
      import_all_history: settings[:import_all_history] == true, account_history: context.fetch(:wise_account_history))
  end

  def initialize(client:, profile_id:, timezone:, import_all_history: false, account_history: nil)
    super(client: client)
    @profile_id = normalized_id(profile_id)
    @timezone = timezone
    @import_all_history = import_all_history
    @account_history = account_history && Provider::AccountData::MigrationManifest.copy_value(account_history)
    if @account_history && (@account_history["format"] != AccountHistory::FORMAT ||
        @account_history["profile_id"] != @profile_id || !@account_history["accounts"].is_a?(Hash))
      raise Provider::AccountData::InvalidResponse, "Invalid Wise retained history context"
    end
  end

  def list_accounts(cursor: nil)
    raise Provider::AccountData::InvalidResponse, "Wise account inventory has no continuation" if cursor
    standard = checked_page(client.get_balances_page(@profile_id, type: "STANDARD"), complete: true)
    savings = checked_page(client.get_balances_page(@profile_id, type: "SAVINGS"), complete: true)
    borderless = checked_page(client.get_borderless_accounts_page(@profile_id), complete: true)
    identifiers = borderless[:items].each_with_object({}) do |raw, mapping|
      data = normalized_object(raw)
      raise ArgumentError unless data[:balances].is_a?(Array)
      data[:balances].each do |balance|
        mapping[normalized_id(normalized_object(balance)[:id])] = { borderless_account_id: data[:id], recipient_id: data[:recipientId] }
      end
    end
    records = (standard[:items] + savings[:items]).map do |raw|
      id = normalized_id(normalized_object(raw)[:id])
      normalize_account(raw, identifiers: identifiers[id] || {})
    end
    Provider::AccountData::Page.new(records: records, complete: true, mode: "snapshot", evidence: {
      "standard" => standard[:evidence] || standard[:items], "savings" => savings[:evidence] || savings[:items],
      "borderless" => borderless[:evidence] || borderless[:items]
    })
  rescue ArgumentError, TypeError, KeyError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Wise account inventory", cause: nil
  end

  def initial_history_start(account:, observed_at:)
    return observed_at - 365.days unless @import_all_history

    created = normalized_object(account[:metadata] || {})[:creation_time].presence
    Time.iso8601(created || "2000-01-01T00:00:00Z").utc
  rescue ArgumentError, TypeError
    raise Provider::AccountData::InvalidResponse, "Invalid Wise account history start", cause: nil
  end

  def statement_profile_id
    @profile_id
  end

  def standard_statement_account?(account)
    !jar?(account)
  end

  # Only the runtime barrier calls this. Denial is an observed result, never an
  # account-local permission to switch endpoints. Other failures remain errors.
  def probe_statement(account:, window:)
    proof = { "profile_id" => @profile_id, "external_account_id" => account[:metadata].fetch("runtime_external_account_id"),
      "window" => window, "outcome" => "success" }
    page = fetch_transactions(account: account, window: window)
    copy_page(page, evidence: page.evidence.merge("wise_statement_probe" => proof))
  rescue Provider::Wise::WiseError => error
    raise unless %i[access_forbidden not_found].include?(error.error_type)
    Provider::AccountData::Page.new(records: [], complete: false, mode: "snapshot", evidence: {
      "wise_statement_probe" => proof.merge("outcome" => "denied"), "error_type" => error.error_type.to_s
    })
  end

  def bind_statement_barrier!(probes:, windows:, header_id:, fingerprint:)
    raise Provider::AccountData::StaleWriter, "Wise statement barrier is already bound" if @statement_barrier
    @statement_barrier = { probes: probes.transform_values(&:freeze).freeze,
      windows: Provider::AccountData::MigrationManifest.copy_value(windows), header_id: header_id.freeze, fingerprint: fingerprint.freeze,
      fallback: probes.any? && probes.values.all? { |probe| probe.fetch("page").evidence.dig("wise_statement_probe", "outcome") == "denied" } }.freeze
    self
  end

  def fetch_transactions(account:, cursor: nil, window: nil)
    scope = requested_window(account, window)
    history = retained_history(account)
    policy = transaction_policy(account, history)
    state = cursor ? decode_cursor(cursor) : { "phase" => jar?(account) ? "activities" : "statements", "cursor" => nil }
    probe = @statement_barrier&.fetch(:probes)&.fetch(account[:external_id], nil)
    fallback = probe && @statement_barrier.fetch(:fallback) && policy[:has_statement_history] != true
    if @statement_barrier && standard_statement_account?(account)
      id = account[:metadata].fetch("runtime_external_account_id")
      unless probe && requested_window(account, @statement_barrier.fetch(:windows).fetch(id)) == scope
        raise Provider::AccountData::StaleWriter, "Wise statement request differs from its profile barrier"
      end
      if state["phase"] == "statements" && state["cursor"].nil?
        captured = probe.fetch("page")
        if captured.evidence.dig("wise_statement_probe", "outcome") == "success"
          return copy_page(captured, evidence: captured.evidence.except(Provider::AccountData::RequestGrant::EVIDENCE_KEY).merge(
            "wise_statement_barrier" => barrier_evidence(probe)))
        end
        raise Provider::AccountData::IncompletePage, "Wise statements were denied without profile-wide fallback authority" unless fallback
        return Provider::AccountData::Page.new(records: [], complete: false, mode: "snapshot",
          next_cursor: encode_cursor(phase: "transfers", cursor: nil),
          coverage: { "start" => scope[:start].iso8601(3), "end" => scope[:end].iso8601(3),
            "history_complete" => false, "pending_absence_authoritative" => false },
          warnings: [ { "code" => "statement_unavailable_transfer_fallback" } ],
          evidence: { "phase" => "statements", "wise_statement_barrier" => barrier_evidence(probe) })
      end
    end
    records, next_state, warnings, evidence = case state.fetch("phase")
    when "statements" then statement_page(account, scope, policy, state)
    when "transfers" then transfer_page(account, scope, state)
    when "activities" then activity_page(account, scope, state)
    else raise ArgumentError
    end
    Provider::AccountData::Page.new(records: records, complete: next_state.nil?, mode: "snapshot",
      next_cursor: next_state ? encode_cursor(next_state) : nil,
      coverage: { "start" => scope[:start].iso8601(3), "end" => scope[:end].iso8601(3) }.merge(
        fallback ? { "history_complete" => false, "pending_absence_authoritative" => false } : {}), warnings: warnings || [],
      evidence: { "phase" => state["phase"], "response" => evidence,
        "wise_account" => { "profile_id" => @profile_id, "external_id" => account[:external_id], "currency" => account[:currency] },
        "retained_history" => history && { "policy" => history.fetch("policy"), "provenance" => history.fetch("provenance") },
        "wise_statement_barrier" => probe && barrier_evidence(probe) })
  rescue ArgumentError, TypeError, KeyError, NoMethodError, JSON::ParserError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Wise transaction page", cause: nil
  end

  def normalize_account(raw, identifiers: {})
    data = normalized_object(raw)
    savings = data[:type] == "SAVINGS"
    raise ArgumentError unless %w[STANDARD SAVINGS].include?(data[:type])
    amount = normalized_object(data.fetch(:amount))
    currency = normalized_currency(amount[:currency].presence || data[:currency])
    worth = savings ? normalized_object(data.fetch(:totalWorth)).fetch(:value) : amount.fetch(:value)
    id = normalized_id(data[:id])
    Ingestion::Record.account(external_id: id,
      name: data[:name].presence || (savings ? "Wise JAR #{currency}" : "Wise #{currency}"),
      currency: currency, account_type: savings ? "SAVINGS" : "STANDARD", balance: normalized_decimal(worth),
      reserved_balance: data[:reservedAmount].nil? ? nil : normalized_decimal(normalized_object(data[:reservedAmount]).fetch(:value)),
      sensitive_details: identifiers.compact,
      metadata: { institution: { name: "Wise", domain: "wise.com" }, balance_type: data[:type], creation_time: data[:creationTime],
        api_name: data[:name],
        balance_policy: { cash_balance: "balance" } })
  rescue ArgumentError, TypeError, KeyError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Wise account", cause: nil
  end

  # A statement can emit the main movement and a separate fee. Both IDs retain
  # the old namespaces so retries and migration can reuse existing ledger entries.
  def normalize_statement(raw, account:)
    data = normalized_object(raw).merge("wise_statement" => true)
    amount = normalized_object(data.fetch(:amount))
    currency = normalized_currency(amount[:currency], fallback: account[:currency])
    signed = normalized_decimal(amount.fetch(:value))
    fee_data = normalized_object(data[:totalFees] || {})
    fee = if fee_data.empty? || (amount[:currency].present? && fee_data[:currency].present? && amount[:currency] != fee_data[:currency])
      BigDecimal("0")
    else
      normalized_decimal(fee_data.fetch(:value))
    end
    raise ArgumentError if fee.negative?
    id = data[:referenceNumber].presence || data[:id].presence || Digest::SHA256.hexdigest(legacy_json(data))[0, 24]
    details = normalized_object(data[:details] || {})
    name = details[:description].presence || details[:reference].presence || data[:referenceNumber].presence || I18n.t("wise_items.entries.default_name")
    name = "#{name} #{details[:paymentReference]}" if details[:paymentReference].present?
    date = normalized_date(data.fetch(:date), timezone: @timezone)
    net = [ signed.abs - fee, BigDecimal("0") ].max
    values = [ record("wise_statement_#{id}", signed.negative? ? net : -net, currency, date, name,
      wise: { statement_id: id, statement_type: data[:type], reference: data[:referenceNumber],
        payment_reference: details[:paymentReference].presence, fee: fee.positive? ? fee : nil }.compact) ]
    if fee.positive?
      values << record("wise_statement_#{id}_fee", fee, currency, date, I18n.t("wise_items.entries.fee_name"),
        wise: { statement_id: id, type: "FEE", fee: fee })
    end
    values
  rescue ArgumentError, TypeError, KeyError, NoMethodError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Wise statement", cause: nil
  end

  def normalize_transfer(raw, account:)
    data = normalized_object(raw)
    id = normalized_id(data[:id])
    source_currency = normalized_currency(data[:sourceCurrency], fallback: account[:currency])
    target_currency = normalized_currency(data[:targetCurrency], fallback: account[:currency])
    source_value = normalized_decimal(data.fetch(:sourceValue))
    target_value = normalized_decimal(data.fetch(:targetValue))
    recipient = normalized_object(account[:sensitive_details] || {})[:recipient_id]
    outgoing = recipient.present? ? data[:targetAccount].to_s != recipient.to_s : !INCOMING_STATUSES.any? { |status| data[:status].to_s.downcase.include?(status) }
    fee = source_currency == target_currency ? [ (source_value - target_value).round(4), BigDecimal("0") ].max : BigDecimal("0")
    rate = data[:rate].present? ? normalized_decimal(data[:rate]) : nil
    rate = nil if rate && !rate.positive?
    reference = normalized_object(data[:details] || {})[:reference].presence || data[:reference].presence
    date = normalized_date(data.fetch(:created), timezone: @timezone)
    extra = { exchange_rate: rate, wise: {
      transfer_id: data[:id], status: data[:status], direction: outgoing ? "outgoing" : "incoming",
      source_currency: source_currency, source_value: data[:sourceValue], target_currency: target_currency,
      target_value: data[:targetValue], rate: data[:rate], fee: fee.positive? ? fee : nil, reference: reference
    }.compact }.compact
    values = [ record("wise_transfer_#{id}", outgoing ? source_value.abs : -target_value.abs,
      source_currency, date, reference || I18n.t("wise_items.entries.default_name"), **extra) ]
    values << record("wise_fee_#{id}", fee, source_currency, date, I18n.t("wise_items.entries.fee_name"), wise: { transfer_id: data[:id], type: "FEE" }) if fee.positive?
    values
  rescue ArgumentError, TypeError, KeyError, NoMethodError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Wise transfer", cause: nil
  end

  def normalize_activity(raw, account:)
    data = normalized_object(raw)
    type = data[:type]
    raise ArgumentError unless ACTIVITY_TYPES.include?(type)
    resource = normalized_object(data[:resource] || {})
    resource_id = resource[:id].to_s
    title = ActionController::Base.helpers.strip_tags(data[:title].to_s)
    deposit = title.downcase.start_with?("to") || title.downcase.include?("received") || title.downcase.include?("added")
    primary = ActionController::Base.helpers.strip_tags(data[:primaryAmount].to_s)
    numeric = primary.scan(/[\d,]+\.?\d*/).first
    raise ArgumentError if numeric.blank?
    amount = normalized_decimal(numeric.delete(",")).abs
    currency = normalized_currency(primary.scan(/\b[A-Z]{3}\b/).first, fallback: account[:currency])
    if type == "INTERBALANCE"
      normalized_id(resource[:id])
      id = "wise_interbalance_#{resource_id}_#{jar?(account) ? 'inflow' : 'outflow'}"
      amount = -amount if jar?(account) ? deposit : !deposit
      name = if jar?(account)
        I18n.t(deposit ? "wise_items.activities.jar_deposit" : "wise_items.activities.jar_withdrawal")
      else
        jar_name = data[:title].to_s.scan(/<strong>([^<]+)<\/strong>/).flatten.last || "Jar"
        I18n.t(deposit ? "wise_items.activities.transfer_to_jar" : "wise_items.activities.transfer_from_jar", jar: jar_name)
      end
    else
      id = "wise_activity_#{normalized_id(data[:id])}"
      amount = -amount if type == "BALANCE_CASHBACK"
      name = I18n.t(type == "BALANCE_CASHBACK" ? "wise_items.activities.interest" : "wise_items.activities.asset_fee")
    end
    # Existing Wise activity entries use the API's calendar date, not family TZ.
    date = DateTime.iso8601(data.fetch(:createdOn)).to_date
    metadata = { extra: { wise: { activity_id: data[:id], activity_type: type,
      resource_type: resource[:type], resource_id: resource_id.presence }.compact } }
    if type == "INTERBALANCE"
      metadata[:transfer_pair] = { key: "wise_interbalance_#{resource_id}", role: amount.negative? ? "inflow" : "outflow", status: "confirmed" }
      proof = InterbalanceTransfers.proof(raw: data, profile_id: @profile_id, account: account, amount: amount)
      metadata[:transfer_pair].merge!(proof) if proof
    end
    Ingestion::Record.transaction(external_id: id, name: name, amount: amount, currency: currency, date: date, pending: false, metadata: metadata)
  rescue ArgumentError, TypeError, KeyError, NoMethodError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Wise activity", cause: nil
  end

  private
    def barrier_evidence(probe)
      { "header_id" => @statement_barrier.fetch(:header_id), "probe_id" => probe.fetch("batch_id"),
        "fingerprint" => @statement_barrier.fetch(:fingerprint), "fallback_authorized" => @statement_barrier.fetch(:fallback) }
    end

    def copy_page(page, evidence:)
      Provider::AccountData::Page.new(records: page.records, complete: page.complete?, mode: page.mode,
        next_cursor: page.next_cursor, checkpoint_cursor: page.checkpoint_cursor, progress_cursor: page.progress_cursor,
        removed_ids: page.removed_ids, coverage: page.coverage, warnings: page.warnings, evidence: evidence)
    end

    def retained_history(account)
      history = @account_history&.fetch("accounts")&.fetch(account[:external_id], nil)
      if history && (history.fetch("currency") != account[:currency] ||
          (history.fetch("balance_type") == "SAVINGS") != jar?(account))
        raise Provider::AccountData::StaleWriter, "Wise retained history belongs to another balance"
      end
      history
    end

    def transaction_policy(account, history)
      # Production factories accept only the reviewed retained collector. The
      # standalone normalizer keeps explicit policy injection for protocol tests;
      # it does not make settings or an account metadata flag a fallback grant.
      return (history ? history.fetch("policy") : {}).with_indifferent_access if @account_history
      normalized_object(account[:metadata] || {}).fetch(:transaction_policy, {}).with_indifferent_access
    end

    def record(id, amount, currency, date, name, **extra)
      Ingestion::Record.transaction(external_id: id, amount: amount, currency: currency, date: date,
        name: name, pending: false, metadata: { extra: extra })
    end

    def statement_page(account, scope, policy, state)
      from = state["cursor"] ? Time.iso8601(state["cursor"]) : scope[:start]
      raise ArgumentError unless from.between?(scope[:start], scope[:end])
      through = [ from + STATEMENT_WINDOW_DAYS.days, scope[:end] ].min
      result = checked_page(client.get_balance_statement_page(@profile_id, account[:external_id], currency: account[:currency], interval_start: from, interval_end: through), complete: true)
      cutoff = policy[:legacy_transfer_cutoff].present? ? Date.iso8601(policy[:legacy_transfer_cutoff]) : nil
      records = result[:items].flat_map do |raw|
        data = normalized_object(raw)
        skip = cutoff && Time.iso8601(data.fetch(:date)).to_date >= cutoff && normalized_decimal(normalized_object(data.fetch(:amount)).fetch(:value)) <= 0
        skip ? [] : normalize_statement(data, account: account)
      end
      next_state = if through < scope[:end]
        { phase: "statements", cursor: through.iso8601(3) }
      else
        { phase: policy[:has_legacy_history] == true && policy[:has_statement_history] != true ? "transfers" : "activities", cursor: nil }
      end
      [ records, next_state, [], result[:evidence] || result[:items] ]
    end

    def transfer_page(account, scope, state)
      result = checked_page(client.get_transfers_page(@profile_id, cursor: state["cursor"]))
      records = result[:items].flat_map do |raw|
        data = normalized_object(raw)
        in_currency = [ data[:sourceCurrency], data[:targetCurrency] ].include?(account[:currency])
        in_currency && in_window?(data[:created], scope) ? normalize_transfer(data, account: account) : []
      end
      [ records, { phase: result[:next_cursor] ? "transfers" : "activities", cursor: result[:next_cursor] }, [], result[:evidence] || result[:items] ]
    end

    def activity_page(account, scope, state)
      result = checked_page(client.get_activities_page(@profile_id, cursor: state["cursor"]))
      records = result[:items].filter_map do |raw|
        data = normalized_object(raw)
        next unless ACTIVITY_TYPES.include?(data[:type]) && in_window?(data[:createdOn], scope)
        if data[:type] == "INTERBALANCE"
          if jar?(account)
            jar_name = data[:title].to_s.scan(/<strong>([^<]+)<\/strong>/).flatten.last.to_s.strip
            next unless jar_name.present? && jar_name.casecmp?(account[:name].to_s.strip)
          end
        else
          next unless jar?(account)
        end
        normalize_activity(data, account: account)
      end
      next_state = { phase: "activities", cursor: result[:next_cursor] } if result[:next_cursor]
      [ records, next_state, [], result[:evidence] || result[:items] ]
    end

    def jar?(account)
      account[:account_type] == "SAVINGS" || normalized_object(account[:metadata] || {})[:balance_type] == "SAVINGS"
    end

    def requested_window(account, window)
      scope = normalized_object(window || {})
      through = scope[:end].present? ? Time.iso8601(scope[:end].to_s) : Time.current.utc
      from = if scope[:start].present?
        Time.iso8601(scope[:start].to_s)
      else
        initial_history_start(account: account, observed_at: through)
      end
      raise ArgumentError if from > through
      { start: from.utc, end: through.utc }
    end

    def in_window?(date, scope)
      Time.iso8601(date).between?(scope[:start], scope[:end])
    end

    def checked_page(result, complete: false)
      unless result.is_a?(Hash) && result[:items].is_a?(Array) && result.key?(:next_cursor) &&
          (result[:next_cursor].nil? || (result[:next_cursor].is_a?(String) && result[:next_cursor].present?)) &&
          (!complete || result[:next_cursor].nil?)
        raise Provider::AccountData::InvalidResponse, "Invalid Wise page"
      end
      result
    end

    def legacy_json(value)
      converted = case value
      when Hash then value.to_h { |key, item| [ key, JSON.parse(legacy_json(item)) ] }
      when Array then value.map { |item| JSON.parse(legacy_json(item)) }
      when BigDecimal then value.to_f # Identity fingerprint only; never used as a monetary value.
      else value
      end
      converted.to_json
    end

    def encode_cursor(state)
      Base64.urlsafe_encode64(JSON.generate(state), padding: false)
    end

    def decode_cursor(cursor)
      state = JSON.parse(Base64.urlsafe_decode64(cursor))
      unless state.is_a?(Hash) && state.keys.sort == %w[cursor phase] && %w[statements transfers activities].include?(state["phase"]) &&
          (state["cursor"].nil? || (state["cursor"].is_a?(String) && state["cursor"].present?))
        raise ArgumentError
      end
      state
    end
end
