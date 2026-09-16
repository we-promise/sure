require "base64"
require "json"
require "digest/md5"

class Provider::AccountData::Akahu < Provider::AccountData::Adapter
  include Provider::AccountData::Normalization

  DEFINITION = Provider::AccountData::Definition.new(
    key: "akahu", source: "akahu", credential_scope: "connection", capabilities: [ "transactions" ],
    fields: [ { name: "app_token", type: "text", secret: true }, { name: "user_token", type: "text", secret: true } ]
  )

  def self.definition
    DEFINITION
  end

  def self.editable_connection_credentials
    %w[app_token user_token]
  end

  def self.account_setup_types
    %w[Depository CreditCard Loan Investment]
  end

  def self.account_setup_defaults(account:, accountable_type:)
    suggestion = {
      "CHECKING" => [ "Depository", "checking" ], "SAVINGS" => [ "Depository", "savings" ],
      "TERMDEPOSIT" => [ "Depository", "cd" ], "CREDITCARD" => [ "CreditCard", "credit_card" ],
      "KIWISAVER" => [ "Investment", "retirement" ], "INVESTMENT" => [ "Investment", nil ]
    }[account.fetch("account_type").to_s.upcase]
    subtype = if accountable_type == "CreditCard"
      "credit_card"
    elsif suggestion&.first == accountable_type
      suggestion.last
    end
    defaults = {}
    defaults["subtype"] = subtype if subtype
    defaults["cash_balance"] = "0" if accountable_type == "Investment"
    defaults
  end

  def self.build(credentials:, settings:, context:)
    credentials = credentials.with_indifferent_access
    new(client: Provider::Akahu.new(app_token: credentials.fetch(:app_token), user_token: credentials.fetch(:user_token)),
      timezone: context.fetch(:timezone))
  end

  def initialize(client:, timezone:)
    super(client: client)
    @timezone = timezone
  end

  def list_accounts(cursor: nil)
    result = checked_page(client.get_accounts_page(cursor: cursor))
    Provider::AccountData::Page.new(records: result[:items].map { |raw| normalize_account(raw) },
      next_cursor: result[:next_cursor], complete: result[:next_cursor].nil?, mode: "snapshot",
      evidence: { "response" => result[:evidence] || result[:items] })
  end

  def self.initial_history_metadata_keys
    [ "akahu_initial_history_start" ]
  end

  def initial_history_start(account:, observed_at:)
    value = account.fetch(:metadata, {})["akahu_initial_history_start"]
    return nil if value.nil? # An omitted start requests all accessible history.

    unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      raise Provider::AccountData::InvalidResponse, "Invalid Akahu initial history date"
    end
    Date.iso8601(value)
  rescue ArgumentError, TypeError
    raise Provider::AccountData::InvalidResponse, "Invalid Akahu initial history date", cause: nil
  end

  def fetch_transactions(account:, cursor: nil, window: nil)
    scope = normalized_object(window || {})
    state = cursor ? decode_cursor(cursor) : { "phase" => "posted", "cursor" => nil }
    if state.fetch("phase") == "posted"
      result = checked_page(client.get_account_transactions_page(account_id: account[:external_id],
        start_date: scope[:start], end_date: scope[:end], cursor: state["cursor"]))
      records = result[:items].map { |raw| normalize_transaction(raw, account: account) }
      next_cursor = encode_cursor(result[:next_cursor] ? "posted" : "pending", result[:next_cursor])
    else
      result = checked_page(client.get_pending_transactions_page(cursor: state["cursor"]))
      occurrences = state.fetch("occurrences", {}).dup
      records = result[:items].filter_map do |raw|
        data = normalized_object(raw)
        remote_account = normalized_id(data[:_account].presence || data[:account].presence || data[:account_id])
        next unless remote_account == account[:external_id]
        record = normalize_transaction(data.merge(_pending: true), account: account)
        if record[:metadata][:identity_policy]
          identity = record[:external_id]
          occurrence = occurrences.fetch(identity, 0)
          occurrences[identity] = occurrence + 1
          record = Ingestion::Record.transaction(**record.attributes.merge(metadata: record[:metadata].merge(identity_occurrence: occurrence)))
        end
        record
      end
      next_cursor = encode_cursor("pending", result[:next_cursor], occurrences: occurrences) if result[:next_cursor]
    end
    Provider::AccountData::Page.new(records: records, next_cursor: next_cursor,
      complete: next_cursor.nil?, mode: "snapshot", coverage: scope.to_h.merge("pending_scope" => "all"),
      evidence: { "phase" => state["phase"], "response" => result[:evidence] || result[:items] })
  rescue ArgumentError, TypeError, KeyError, NoMethodError, JSON::ParserError
    raise Provider::AccountData::InvalidResponse, "Invalid Akahu transaction page", cause: nil
  end

  def normalize_account(raw)
    data = normalized_object(raw)
    balance = normalized_object(data.fetch(:balance))
    connection = normalized_object(data[:connection] || {})
    meta = normalized_object(data[:meta] || {})
    payment = normalized_object(meta[:payment_details] || {})
    name = [ connection[:name].presence, data[:name].presence ].compact.join(" - ").presence || I18n.t("akahu_account.fallback")
    Ingestion::Record.account(
      external_id: normalized_id(data[:_id].presence || data[:id]), name: name,
      currency: normalized_currency(balance.fetch(:currency)), balance: normalized_decimal(balance.fetch(:current)),
      available_balance: balance[:available].nil? ? nil : normalized_decimal(balance[:available]),
      account_type: data[:type],
      sensitive_details: {
        account_number: data[:formatted_account].presence || payment[:account_number],
        holder: meta[:holder].presence || payment[:account_holder]
      }.compact,
      metadata: {
        institution: { id: connection[:_id].presence || connection[:id], name: connection[:name], logo: connection[:logo] }.compact,
        status: data[:status], balance_limit: balance[:limit].nil? ? nil : normalized_decimal(balance[:limit]),
        balance_policy: { debt_transform: "absolute", debt_types: %w[CreditCard Loan], investment_cash_zero: true, cash_balance: "balance" }
      }
    )
  rescue ArgumentError, TypeError, KeyError, NoMethodError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Akahu account", cause: nil
  end

  def normalize_transaction(raw, account:)
    data = normalized_object(raw)
    remote_account = normalized_id(data[:_account].presence || data[:account].presence || data[:account_id])
    raise ArgumentError unless remote_account == account[:external_id]
    merchant = normalized_object(data[:merchant] || {})
    merchant_name = merchant[:name].to_s.strip.presence
    category = normalized_object(data[:category] || {})
    meta = normalized_object(data[:meta] || {})
    name = merchant_name || data[:description].presence || I18n.t("transactions.unknown_name")
    id = data[:_id].presence || data[:id].presence
    pending = ActiveModel::Type::Boolean.new.cast(data[:_pending]) == true || ActiveModel::Type::Boolean.new.cast(data[:pending]) == true
    notes = []
    notes << data[:description] if data[:description].present? && data[:description] != name
    %i[reference particulars code other_account].each do |field|
      notes << "#{I18n.t("akahu_entry.notes.#{field}")}: #{meta[field]}" if meta[field].present?
    end
    Ingestion::Record.transaction(
      external_id: id ? "akahu_#{normalized_id(id)}" : synthetic_id(data, merchant_name),
      name: name, amount: -normalized_decimal(data.fetch(:amount)),
      currency: normalized_currency(data[:currency], fallback: account[:currency]),
      date: normalized_date(data.fetch(:date), timezone: @timezone), pending: pending,
      metadata: {
        identity_policy: id ? nil : "reuse_pending_or_allocate_suffix", notes: notes.presence&.join(" | "),
        pending_match_policy: id && !pending ? { source: "akahu", backward_days: 8, amount: "exact", currency: "exact" } : nil,
        merchant: merchant_name ? {
          external_id: merchant[:_id].presence || merchant[:id].presence || "akahu_merchant_#{Digest::MD5.hexdigest(merchant_name.downcase)}",
          name: merchant_name, website_url: merchant[:website]
        }.compact : nil,
        extra: { "akahu" => {
          "pending" => pending, "type" => data[:type], "category" => category[:name],
          "category_id" => category[:_id].presence || category[:id],
          "category_group" => category.dig(:groups, :personal_finance, :name),
          "reference" => meta[:reference], "particulars" => meta[:particulars],
          "code" => meta[:code], "other_account" => meta[:other_account]
        }.compact }
      }
    )
  rescue ArgumentError, TypeError, KeyError, NoMethodError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Akahu transaction", cause: nil
  end

  # Historical JSON caches used Float decoding. Match the original processor's
  # decimal conversion without relaxing exact-money parsing on new API reads.
  def normalize_legacy_transaction(raw, account:)
    data = normalized_object(raw)
    if data[:amount].is_a?(Float)
      raise Provider::AccountData::InvalidResponse, "Invalid Akahu cached amount" unless data[:amount].finite?
      data = data.merge(amount: data[:amount].to_s)
    end
    normalize_transaction(data, account: account)
  rescue ArgumentError, TypeError
    raise Provider::AccountData::InvalidResponse, "Invalid Akahu cached transaction", cause: nil
  end

  private
    def checked_page(result)
      unless result.is_a?(Hash) && result[:items].is_a?(Array) && result.key?(:next_cursor) &&
          (result[:next_cursor].nil? || (result[:next_cursor].is_a?(String) && result[:next_cursor].present?))
        raise Provider::AccountData::InvalidResponse, "Invalid Akahu page"
      end
      result
    end

    def synthetic_id(data, merchant_name)
      # Only this legacy identity fingerprint uses Float formatting. Financial
      # values stay exact; old JSON decoding used Float#to_s in this digest.
      amount_identity = data[:amount].is_a?(BigDecimal) ? data[:amount].to_f.to_s : data[:amount]
      values = [ data[:_account], data[:account], data[:date], amount_identity, data[:description], merchant_name, data[:type] ]
      "akahu_pending_#{Digest::MD5.hexdigest(values.compact.join('|'))}"
    end

    def encode_cursor(phase, cursor, occurrences: nil)
      state = { phase: phase, cursor: cursor }
      state[:occurrences] = occurrences if occurrences
      Base64.urlsafe_encode64(JSON.generate(state), padding: false)
    end

    def decode_cursor(cursor)
      state = JSON.parse(Base64.urlsafe_decode64(cursor))
      unless state.is_a?(Hash) && (state.keys - %w[cursor phase occurrences]).empty? && state.key?("cursor") && %w[posted pending].include?(state["phase"]) &&
          (state["cursor"].nil? || (state["cursor"].is_a?(String) && state["cursor"].present?))
        raise ArgumentError
      end
      if state.key?("occurrences")
        raise ArgumentError unless state["phase"] == "pending" && state["occurrences"].is_a?(Hash) &&
          state["occurrences"].all? { |key, value| key.is_a?(String) && key.match?(/\Aakahu_pending_[a-f0-9]{32}\z/) && value.is_a?(Integer) && value >= 0 }
      end
      state
    end
end
