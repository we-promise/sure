require "base64"
require "json"
require "digest/md5"

class Provider::AccountData::Monobank < Provider::AccountData::Adapter
  include Provider::AccountData::Normalization
  include IsoNumericCurrency
  include CategoryTaxonomy

  DEFINITION = Provider::AccountData::Definition.new(
    key: "monobank", source: "monobank", credential_scope: "connection", capabilities: [ "transactions" ],
    fields: [ { name: "access_token", type: "text", secret: true }, { name: "sync_start_date", type: "string", secret: false } ]
  )

  def self.definition
    DEFINITION
  end

  def self.native_ready?
    false
  end

  def self.runtime_options
    %i[include_pending max_statement_requests_per_sync pending_lookback_days initial_history_days]
  end

  def self.external_account_inputs
    { mutable: [ "sync_start_date" ], frozen: [], inventory: "linked" }
  end

  def self.frozen_context_sources
    [ :monobank_retained_history ]
  end

  def self.context_sources
    %i[external_accounts monobank_retained_history]
  end

  def self.build(credentials:, settings:, context:)
    options = context.fetch(:configured_options, {}).with_indifferent_access
    new(client: Provider::Monobank.new(credentials.with_indifferent_access.fetch(:access_token)),
      timezone: context.fetch(:timezone), observed_at: context.fetch(:observed_at),
      include_pending: options.fetch(:include_pending, true),
      request_budget: options.fetch(:max_statement_requests_per_sync, 4),
      pending_lookback_days: options.fetch(:pending_lookback_days, 3), initial_history_days: options.fetch(:initial_history_days, 31),
      sync_start_date: settings.with_indifferent_access[:sync_start_date], account_states: account_states_from(context))
  end

  def self.account_states_from(context)
    retained = context.fetch(:monobank_retained_history).with_indifferent_access
    accounts = context.fetch(:external_accounts).map(&:with_indifferent_access).select { |account| account[:linked_account] }
    unless retained[:version] == RetainedHistory::VERSION && retained[:accounts].is_a?(Hash) &&
        accounts.map { |account| account.fetch(:id) }.sort == retained[:accounts].keys.sort
      raise Provider::AccountData::StaleWriter, "Monobank retained account inventory differs from its factory inputs"
    end
    states = accounts.to_h do |account|
      row = retained[:accounts].fetch(account.fetch(:id)).with_indifferent_access
      proof = row.fetch(:context).with_indifferent_access
      link = account.fetch(:linked_account).with_indifferent_access
      binding = proof.fetch(:account_binding).with_indifferent_access
      unless proof.values_at(:external_id, :identity_namespace, :sync_start_date) == account.values_at(:external_id, :identity_namespace, :sync_start_date) &&
          binding.fetch(:link).values_at("id", "account_id", "external_account_id", "lock_version") ==
            [ link.fetch(:account_provider_id), link.fetch(:id), account.fetch(:id), link.fetch(:account_provider_revision) ] &&
          binding.fetch(:financial_context).values_at("id", "currency", "accountable_type", "accountable_id") ==
            link.values_at(:id, :currency, :accountable_type, :accountable_id)
        raise Provider::AccountData::StaleWriter, "Monobank retained history belongs to another linked account"
      end
      [ account.fetch(:id), { "external_id" => account.fetch(:external_id), "identity_namespace" => account.fetch(:identity_namespace),
        "state" => row.fetch(:state).merge("sync_start_date" => account[:sync_start_date]) } ]
    end
    { "version" => RetainedHistory::VERSION, "accounts" => states }
  rescue KeyError, TypeError, NoMethodError
    raise Provider::AccountData::StaleWriter, "Monobank factory requires its explicit retained history input", cause: nil
  end

  def initialize(client:, timezone:, observed_at:, include_pending: true, request_budget: 4,
    pending_lookback_days: 3, initial_history_days: 31, sync_start_date: nil, account_states: {})
    super(client: client)
    @timezone = timezone
    @observed_at = observed_at.to_time.getutc
    @include_pending = include_pending == true
    @requests_remaining = positive_integer(request_budget, maximum: 60)
    @pending_lookback_days = positive_integer(pending_lookback_days, maximum: 31)
    @initial_history_days = positive_integer(initial_history_days, maximum: 3650)
    @sync_start_date = sync_start_date
    @account_states = account_states.with_indifferent_access
  end

  def list_accounts(cursor: nil)
    raise ArgumentError if cursor
    result = checked_page(client.get_accounts_page)
    raise ArgumentError if result[:next_cursor]
    records = result[:items].map { |raw| normalize_account(raw) }
    warnings = result[:items].filter_map do |raw|
      { "code" => "unrecognized_account_currency" } unless alpha_currency_code(normalized_object(raw)[:currencyCode])
    end
    Provider::AccountData::Page.new(records: records, complete: true, mode: "snapshot", warnings: warnings,
      evidence: { "response" => result[:evidence] || result[:items] })
  rescue Provider::Monobank::RateLimitError
    raise Provider::AccountData::IncompletePage, "Monobank account inventory was rate limited", cause: nil
  rescue ArgumentError, TypeError, KeyError, NoMethodError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Monobank account inventory", cause: nil
  end

  def fetch_transactions(account:, cursor: nil, window: nil)
    saved = retained_state_for(account)
    persisted = cursor ? decode_cursor(cursor) : nil
    state = persisted && persisted["phase"] != "checkpoint" ? persisted : initial_state(saved, window, persisted)
    raise Provider::AccountData::BudgetExhausted, "Monobank statement request budget exhausted" if @requests_remaining <= 0
    result = checked_page(client.get_statement_page(account_id: account[:external_id], from: Time.at(state.fetch("from")).utc,
      to: Time.at(state.fetch("to")).utc, before_request: method(:spend_request!)))
    raise ArgumentError if result[:next_cursor] || result[:items].size > Provider::Monobank::MAX_STATEMENT_ITEMS
    timestamps = result[:items].map do |raw|
      value = transaction_time(normalized_object(raw).fetch(:time))
      raise ArgumentError unless value.between?(state.fetch("from"), state.fetch("to"))
      value
    end
    records = result[:items].map { |raw| normalize_transaction(raw, account: account) }
    pending_times = records.each_with_index.filter_map do |record, index|
      timestamps[index] if @include_pending && record[:pending] && timestamps[index] >= state.fetch("observed_end") - Provider::Monobank::MAX_STATEMENT_WINDOW
    end
    state = state.merge("oldest_pending_at" => [ state["oldest_pending_at"], pending_times.min ].compact.min)
    records.reject! { |record| record[:pending] } unless @include_pending
    warnings = result[:items].filter_map { |raw| operation_warning(raw, account) }
    next_state, final_state = advance_state(state, timestamps)
    warnings << { "code" => "statement_item_cap" } if timestamps.size == Provider::Monobank::MAX_STATEMENT_ITEMS
    coverage = { "start" => Time.at(state.fetch("forward_from")).utc.iso8601,
      "end" => Time.at(state.fetch("observed_end")).utc.iso8601,
      "pending_absence_authoritative" => next_state.nil? && state["observed_end"] == @observed_at.to_i,
      "pending_expired_before" => Time.at(state.fetch("observed_end") - Provider::Monobank::MAX_STATEMENT_WINDOW).utc.iso8601 }
    coverage["pending_scope"] = "all" unless @include_pending
    continuation = next_state ? encode_cursor(next_state) : nil
    Provider::AccountData::Page.new(records: records, complete: next_state.nil?, mode: "snapshot",
      next_cursor: continuation, progress_cursor: continuation, checkpoint_cursor: final_state ? encode_cursor(final_state) : nil,
      coverage: coverage, warnings: warnings, evidence: { "response" => result[:evidence] || result[:items] })
  rescue Provider::Monobank::RateLimitError
    raise Provider::AccountData::IncompletePage, "Monobank statement work was rate limited", cause: nil
  rescue ArgumentError, TypeError, KeyError, NoMethodError, JSON::ParserError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Monobank transaction page", cause: nil
  end

  def normalize_account(raw)
    data = normalized_object(raw)
    raise ArgumentError unless %w[card jar].include?(data[:kind])
    currency = known_currency(alpha_currency_code(data[:currencyCode])) || "UAH"
    divisor = BigDecimal(minor_unit_divisor(currency).to_s)
    credit = data[:creditLimit].nil? ? BigDecimal("0") : minor_units(data[:creditLimit])
    own_funds = (minor_units(data.fetch(:balance)) - credit) / divisor
    type = data[:kind] == "jar" ? "jar" : data[:type]
    label = I18n.t("monobank_account.card_types.#{type.to_s.downcase.presence || 'unknown'}", default: I18n.t("monobank_account.card_types.unknown"))
    masked_pan = Array(data[:maskedPan]).first.presence
    last_four = masked_pan.to_s[-4..]
    name = data[:kind] == "jar" ? data[:title].presence || I18n.t("monobank_account.jar_fallback") : last_four.present? ? "#{label} ·#{last_four}" : label
    Ingestion::Record.account(external_id: normalized_id(data[:id]), name: name, currency: currency,
      account_type: type, balance: own_funds, cash_balance: own_funds,
      sensitive_details: { masked_pan: masked_pan, iban: data[:iban].presence }.compact,
      metadata: { institution: { name: "Monobank", domain: "monobank.ua" }, account_kind: data[:kind],
        credit_limit: credit / divisor, balance_policy: { cash_balance: "balance" } })
  rescue ArgumentError, TypeError, KeyError, NoMethodError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Monobank account", cause: nil
  end

  def normalize_transaction(raw, account:)
    data = normalized_object(raw)
    if data[:account_id].present? && normalized_id(data[:account_id]) != account[:external_id]
      raise ArgumentError
    end
    data = data.merge(account_id: account[:external_id])
    currency = normalized_currency(account[:currency])
    divisor = BigDecimal(minor_unit_divisor(currency).to_s)
    id = data[:id].present? ? "monobank_#{normalized_id(data[:id])}" : "monobank_pending_#{Digest::MD5.hexdigest([ data[:account_id], data[:time], data[:amount], data[:description] ].compact.join('|'))}"
    pending = ActiveModel::Type::Boolean.new.cast(data[:hold]) == true
    merchant_name = data[:description].to_s.strip.presence
    operation_currency = known_currency(alpha_currency_code(data[:currencyCode]))
    foreign = operation_currency && operation_currency != currency
    operation_amount = data[:operationAmount]
    fx_amount = optional_major_amount(operation_amount, BigDecimal(minor_unit_divisor(operation_currency).to_s)) if foreign
    group = mcc_group(data[:mcc])
    extra = { "pending" => pending, "mcc" => data[:mcc], "original_mcc" => data[:originalMcc],
      "cashback_amount" => optional_major_amount(data[:cashbackAmount], divisor),
      "commission_amount" => optional_major_amount(data[:commissionRate], divisor), "balance_after" => optional_major_amount(data[:balance], divisor),
      "operation_amount" => operation_amount.present? && operation_amount.to_s != data[:amount].to_s ? operation_amount : nil,
      "fx_from" => foreign ? operation_currency : nil, "fx_amount" => fx_amount,
      "counter_name" => data[:counterName], "counter_iban" => data[:counterIban], "counter_edrpou" => data[:counterEdrpou],
      "receipt_id" => data[:receiptId], "invoice_id" => data[:invoiceId] }.compact
    Ingestion::Record.transaction(external_id: id, name: data[:description].presence || I18n.t("transactions.unknown_name"),
      amount: -minor_units(data.fetch(:amount)) / divisor, currency: currency,
      date: Time.at(transaction_time(data.fetch(:time))).in_time_zone(@timezone).to_date, pending: pending,
      metadata: { notes: data[:comment].presence, extra: { "monobank" => extra },
        category_candidates: group ? { translation_key: group[:key].to_s, aliases: group[:aliases] } : nil,
        merchant: merchant_name ? { external_id: "monobank_merchant_#{Digest::MD5.hexdigest(merchant_name.downcase)}", name: merchant_name } : nil }.compact)
  rescue ArgumentError, TypeError, KeyError, NoMethodError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Monobank transaction", cause: nil
  end

  private
    def spend_request!
      raise Provider::AccountData::BudgetExhausted, "Monobank statement request budget exhausted" if @requests_remaining <= 0
      @requests_remaining -= 1
    end

    def positive_integer(value, maximum:)
      raise ArgumentError unless value.is_a?(Integer) && value.between?(1, maximum)
      value
    end

    def minor_units(value)
      value = normalized_decimal(value)
      raise ArgumentError unless value.frac.zero?
      value
    end

    def optional_major_amount(value, divisor)
      return nil if value.blank?
      (minor_units(value) / divisor).to_s("F")
    rescue ArgumentError
      nil
    end

    def transaction_time(value)
      return value if value.is_a?(Integer)
      return Integer(value, 10) if value.is_a?(String) && value.match?(/\A-?\d+\z/)
      return Time.iso8601(value).to_i if value.is_a?(String)
      return value.to_time.to_i if value.is_a?(Time) || value.is_a?(DateTime)
      return value.in_time_zone(@timezone).to_i if value.instance_of?(Date)
      raise ArgumentError
    end

    def operation_warning(raw, account)
      data = normalized_object(raw)
      currency = known_currency(alpha_currency_code(data[:currencyCode]))
      return unless currency && currency != account[:currency] && data[:operationAmount].present?
      minor_units(data[:operationAmount])
      nil
    rescue ArgumentError
      { "code" => "unparseable_operation_amount" }
    end

    def initial_state(saved, window, checkpoint)
      scope = normalized_object(window || {})
      # An explicit per-sync end is fixed in the cursor for later budgeted resumes.
      window_end = scope[:end]
      observed_end = window_end ? [ Time.iso8601(window_end).to_i, @observed_at.to_i ].min : @observed_at.to_i
      target_date = saved[:sync_start_date].presence || @sync_start_date
      target = if scope[:explicit_start] == true
        Time.iso8601(scope.fetch(:start)).to_i
      else
        target_date ? history_date(target_date) : observed_end - @initial_history_days.days.to_i
      end
      previous = checkpoint ? checkpoint["through"] : optional_time(saved[:statement_synced_through])
      history_from = checkpoint ? checkpoint["history_from"] : optional_time(saved[:history_synced_from])
      oldest_hold = if @include_pending
        checkpoint ? checkpoint["oldest_pending_at"] : optional_time(saved[:oldest_pending_at])
      end
      requested = previous ? [ previous, observed_end - @pending_lookback_days.days.to_i, oldest_hold ].compact.min : target
      from = [ requested, observed_end - Provider::Monobank::MAX_STATEMENT_WINDOW ].max
      raise ArgumentError if from > observed_end || target > observed_end
      { "version" => 1, "phase" => "forward", "from" => from, "to" => observed_end,
        "window_from" => from, "window_to" => observed_end, "forward_from" => from,
        "target" => target, "observed_end" => observed_end, "previous_through" => previous,
        "history_from" => history_from, "oldest_pending_at" => nil }
    end

    def retained_state_for(account)
      # Pure adapter callers may still provide explicitly scoped test states.
      # Factories always use UUID/namespace-bound collector output.
      return normalized_object(@account_states[account[:external_id]] || {}) unless @account_states[:version] == RetainedHistory::VERSION

      metadata = normalized_object(account[:metadata] || {})
      row = @account_states.fetch(:accounts).fetch(metadata.fetch(:runtime_external_account_id)).with_indifferent_access
      unless row[:external_id] == account[:external_id] && row[:identity_namespace] == metadata.fetch(:runtime_identity_namespace)
        raise Provider::AccountData::StaleWriter, "Monobank request account differs from its retained history"
      end
      normalized_object(row.fetch(:state))
    rescue KeyError, TypeError, NoMethodError
      raise Provider::AccountData::StaleWriter, "Monobank request has no retained account context", cause: nil
    end

    def advance_state(state, timestamps)
      if timestamps.size == Provider::Monobank::MAX_STATEMENT_ITEMS
        oldest = timestamps.min
        if oldest >= state.fetch("to")
          raise Provider::AccountData::IncompletePage, "Monobank item cap prevents timestamp pagination from advancing"
        end
        return [ state.merge("to" => oldest), nil ]
      end
      history_from = if state["phase"] == "history"
        state.fetch("window_from")
      elsif state["previous_through"] && state["window_from"] > state["previous_through"]
        state.fetch("window_from")
      else
        [ state["history_from"], state.fetch("window_from") ].compact.min
      end
      if state["phase"] == "forward" && history_from > state.fetch("target") && @requests_remaining.positive?
        from = [ state.fetch("target"), history_from - Provider::Monobank::MAX_STATEMENT_WINDOW ].max
        return [ state.merge("phase" => "history", "from" => from, "to" => history_from,
          "window_from" => from, "window_to" => history_from, "history_from" => history_from), nil ]
      end
      [ nil, { "version" => 1, "phase" => "checkpoint", "through" => state.fetch("observed_end"),
        "history_from" => history_from, "oldest_pending_at" => state["oldest_pending_at"] } ]
    end

    def optional_time(value)
      return nil if value.blank?
      value.is_a?(String) ? Time.iso8601(value).to_i : value.to_time.to_i
    end

    def history_date(value)
      return value.in_time_zone(@timezone).to_i if value.instance_of?(Date)
      return Date.iso8601(value).in_time_zone(@timezone).to_i if value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      optional_time(value)
    end

    def encode_cursor(state)
      Base64.urlsafe_encode64(JSON.generate(state), padding: false)
    end

    def decode_cursor(cursor)
      state = JSON.parse(Base64.urlsafe_decode64(cursor))
      raise ArgumentError unless state.is_a?(Hash) && state["version"] == 1 && %w[forward history checkpoint].include?(state["phase"])
      required = state["phase"] == "checkpoint" ? %w[through history_from] : %w[from to window_from window_to forward_from target observed_end]
      raise ArgumentError unless required.all? { |key| state[key].is_a?(Integer) }
      optional = state["phase"] == "checkpoint" ? %w[oldest_pending_at] : %w[previous_through history_from oldest_pending_at]
      raise ArgumentError unless (state.keys - required - optional - %w[version phase]).empty?
      raise ArgumentError unless optional.all? { |key| state[key].nil? || state[key].is_a?(Integer) }
      unless state["phase"] == "checkpoint"
        raise ArgumentError unless state["from"] <= state["to"] && state["to"] <= state["window_to"] &&
          state["window_from"] == state["from"] && state["window_to"] <= state["observed_end"] &&
          state["to"] - state["from"] <= Provider::Monobank::MAX_STATEMENT_WINDOW
      end
      state
    end
end
