class YaxiAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  ACCOUNT_TYPE_MAP = {
    "Current" => [ "Depository", "checking" ],
    "Savings" => [ "Depository", "savings" ],
    "CallMoney" => [ "Depository", "money_market" ],
    "TimeDeposit" => [ "Depository", "cd" ],
    "Card" => [ "CreditCard", "credit_card" ],
    "Loan" => [ "Loan", nil ],
    "Securities" => [ "Investment", "brokerage" ],
    "Insurance" => [ "OtherAsset", nil ],
    "Commerce" => [ "Depository", "checking" ],
    "Rewards" => [ "OtherAsset", nil ]
  }.freeze

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :yaxi_item
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account

  validates :external_id, :name, :currency, presence: true
  validates :external_id, uniqueness: { scope: :yaxi_item_id }

  def reference
    { iban: iban.presence, number: number.presence, currency: currency }.compact
  end

  def self.external_id_for(snapshot)
    data = snapshot.with_indifferent_access
    stable_value = data[:iban].presence || data[:number].presence
    raise Provider::Yaxi::InvalidResultError, "YAXI account has no stable identifier" if stable_value.blank?

    Digest::SHA256.hexdigest([ stable_value, data[:currency] ].join("\x1F"))
  end

  def apply_snapshot!(snapshot)
    data = snapshot.with_indifferent_access
    self.external_id = self.class.external_id_for(data)
    self.iban = data[:iban]
    self.number = data[:number]
    self.bic = data[:bic]
    self.currency = parse_currency(data[:currency]) || "EUR"
    self.account_type = data[:type]
    self.account_status = data[:status]
    self.name = data[:displayName].presence || data[:name].presence || fallback_name(data)
    self.raw_payload = snapshot
    save!
  end

  def ensure_linked_account!
    return account if account_provider.present?

    accountable_type, subtype = ACCOUNT_TYPE_MAP.fetch(account_type, [ "Depository", "checking" ])
    internal_account = Account.create_and_sync(
      {
        family: yaxi_item.family,
        name: name,
        balance: 0,
        currency: currency,
        accountable_type: accountable_type,
        accountable_attributes: subtype.present? ? { subtype: subtype } : {}
      },
      skip_initial_sync: true
    )
    create_account_provider!(account: internal_account)
    internal_account
  end

  def apply_balance_result!(balances)
    candidates = (balances.is_a?(Array) ? balances : [ balances ]).map(&:with_indifferent_access)
    chosen = %w[Booked Expected Available].filter_map do |kind|
      candidates.find { |balance| balance[:balanceType] == kind }
    end.first
    return if chosen.blank?

    amount = BigDecimal(chosen.fetch(:amount).to_s)
    amount = amount.abs if account&.liability?
    normalized_currency = parse_currency(chosen[:currency]) || currency

    transaction do
      update!(current_balance: amount, currency: normalized_currency)
      account.update!(currency: normalized_currency, cash_balance: amount)
      result = account.set_current_balance(amount)
      raise result.error if result.error
    end
  end

  def import_transactions!(transactions, from: nil)
    payloads = transactions.is_a?(Array) ? transactions : [ transactions ]
    flattened = payloads.flat_map do |transaction|
      data = transaction.with_indifferent_access
      if data[:transactions].present?
        Array(data[:transactions])
      elsif data.dig(:batch, :transactions).present?
        Array(data.dig(:batch, :transactions))
      else
        data
      end
    end

    transaction do
      self.raw_transactions_payload = flattened
      save!

      adapter = Account::ProviderImportAdapter.new(account)
      dated, undated = flattened.partition { |entry| transaction_date(entry.with_indifferent_access).present? }
      capture_undated_transactions(undated) if undated.any?
      current_pending_external_ids = dated.filter_map do |entry|
        data = entry.with_indifferent_access
        transaction_external_id(data) if data[:status].to_s == "Pending"
      end
      dated.each { |entry| import_transaction!(entry.with_indifferent_access, adapter) }
      reconcile_pending_entries!(current_pending_external_ids, from: from) if from
    end
  end

  private

    def fallback_name(data)
      identifier = data[:iban].presence || data[:number].presence
      key = identifier.present? ? "with_identifier" : "without_identifier"
      I18n.t("yaxi_items.account.fallback_name.#{key}", identifier: identifier&.last(4))
    end

    def import_transaction!(data, adapter)
      raw_amount = BigDecimal(data.dig(:amount, :amount).to_s, exception: false)
      return capture_unparsable_amount(data) if raw_amount.nil?

      status = data[:status].to_s
      return if status.in?(%w[Canceled])

      adapter.import_transaction(
        external_id: transaction_external_id(data),
        amount: -raw_amount,
        currency: parse_currency(data.dig(:amount, :currency)) || currency,
        date: transaction_date(data),
        name: transaction_name(data, raw_amount),
        source: "yaxi",
        notes: Array(data[:remittanceInformation]).compact_blank.join("\n").presence,
        extra: {
          yaxi: {
            pending: status == "Pending",
            status: status,
            purpose_code: data[:purposeCode],
            end_to_end_id: data[:endToEndId]
          }.compact
        }
      )
    end

    def transaction_external_id(data)
      identifier = [ data[:accountServicerReference], data[:transactionId], data[:entryReference] ]
        .find { |value| stable_transaction_reference?(value) }
      return "yaxi_#{identifier}" if identifier

      digest_input = [
        transaction_date(data), data.dig(:amount, :amount), data.dig(:amount, :currency),
        data[:endToEndId], data[:paymentId], data.dig(:creditor, :name), data.dig(:debtor, :name),
        Array(data[:remittanceInformation]).join("|")
      ].join("\x1F")
      "yaxi_content_#{Digest::SHA256.hexdigest(digest_input)}"
    end

    def reconcile_pending_entries!(current_pending_external_ids, from:)
      pending_entries = account.entries
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(source: "yaxi")
        .where("(transactions.extra -> 'yaxi' ->> 'pending')::boolean = true")

      missing = pending_entries.where(date: from..Date.current)
      missing = missing.where.not(external_id: current_pending_external_ids) if current_pending_external_ids.any?
      pruned_count = missing.count
      missing.find_each(&:destroy!) if pruned_count.positive?

      history_boundary = 90.days.ago.to_date
      out_of_range = pending_entries.where("entries.date < ?", history_boundary).where(excluded: false)
      excluded_count = out_of_range.update_all(excluded: true, updated_at: Time.current)
      capture_pending_reconciliation(pruned_count, excluded_count, from) if pruned_count.positive? || excluded_count.positive?
    end

    def capture_pending_reconciliation(pruned_count, excluded_count, from)
      DebugLogEntry.capture(
        category: "sync",
        level: "info",
        message: "Reconciled stale YAXI pending transactions",
        source: "YaxiAccount#import_transactions!",
        provider_key: "yaxi",
        family: yaxi_item.family,
        account_provider: account_provider,
        metadata: {
          yaxi_account_id: id,
          range_from: from.iso8601,
          pruned_count: pruned_count,
          excluded_out_of_range_count: excluded_count
        }
      )
    end

    def transaction_date(data)
      raw_date = data[:bookingDate].presence || data[:valueDate].presence || data[:transactionDate].presence
      return if raw_date.blank?

      Date.parse(raw_date.to_s)
    rescue Date::Error
      nil
    end

    def capture_undated_transactions(transactions)
      statuses = transactions.map { |transaction| transaction.with_indifferent_access[:status] }.compact.tally
      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "Skipped YAXI transactions without a valid date",
        source: "YaxiAccount#import_transactions!",
        provider_key: "yaxi",
        family: yaxi_item.family,
        account_provider: account_provider,
        metadata: { yaxi_account_id: id, skipped_count: transactions.size, statuses: statuses }
      )
    end

    def capture_unparsable_amount(data)
      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "Skipped YAXI transaction with an unparsable amount",
        source: "YaxiAccount#import_transaction!",
        provider_key: "yaxi",
        family: yaxi_item.family,
        account_provider: account_provider,
        metadata: { yaxi_account_id: id, amount: data.dig(:amount, :amount), status: data[:status] }
      )
    end

    def stable_transaction_reference?(value)
      value.present? && !value.to_s.casecmp("NOTPROVIDED").zero?
    end

    def transaction_name(data, raw_amount)
      party = raw_amount.negative? ? data.dig(:creditor, :name) : data.dig(:debtor, :name)
      party.presence || Array(data[:remittanceInformation]).compact_blank.first.presence ||
        I18n.t("yaxi_items.transactions.#{raw_amount.negative? ? 'outgoing' : 'incoming'}")
    end

    def log_invalid_currency(value)
      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "YAXI returned an invalid currency",
        source: "YaxiAccount#log_invalid_currency",
        provider_key: "yaxi",
        family: yaxi_item.family,
        account_provider: account_provider,
        metadata: { yaxi_account_id: id, currency: value }
      )
    end
end
