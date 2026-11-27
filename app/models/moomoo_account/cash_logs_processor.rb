class MoomooAccount::CashLogsProcessor
  include MoomooAccount::DataHelpers

  # The cash log names each row's kind. Trades come from the fills, and a
  # money market fund the broker sweeps cash into (moomoo Cash Plus) counts as
  # cash, so the rows that move cash into trades or such funds are skipped.
  EXCHANGE = /\Acurrency exchange/i
  RULES = [
    [ /\Abank transfer deposit/i, { label: "Contribution", kind: "funds_movement" } ],
    [ /\Abank transfer withdrawal/i, { label: "Withdrawal", kind: "funds_movement" } ],
    [ EXCHANGE, { label: "Exchange", kind: "funds_movement" } ],
    [ /tax/i, { label: "Fee", kind: "standard" } ],
    [ /dividend|coupon/i, { label: "Dividend", kind: "standard" } ],
    [ /interest/i, { label: "Interest", kind: "standard" } ],
    [ /fee\z/i, { label: "Fee", kind: "standard" } ],
    [ /execution\z|\Afund (subscription|redemption)/i, :skip ]
  ].freeze

  # The zone each broker entity writes cash log times in. Only Singapore's has
  # been seen; the others are their home markets'.
  FIRM_TIME_ZONES = {
    "FUTUSG" => "Asia/Singapore",
    "FUTUSECURITIES" => "Asia/Hong_Kong",
    "FUTUINC" => "America/New_York",
    "FUTUMY" => "Asia/Kuala_Lumpur",
    "FUTUAU" => "Australia/Sydney",
    "FUTUJP" => "Asia/Tokyo",
    "FUTUCA" => "America/Toronto"
  }.freeze

  TIME_FORMATS = [ "%m/%d/%Y %H:%M:%S", "%Y-%m-%d %H:%M:%S" ].freeze

  # Deposits and withdrawals on a cash account move money between the user's
  # own cash, so they carry no activity label there: a Contribution label
  # would make the import adapter book them as investment contributions.
  CASH_ACCOUNT_UNLABELED = %w[Contribution Withdrawal].freeze
  EXTERNAL_ID_PREFIX = "moomoo_cash_log_".freeze

  # Whether the transfer links the two rows moomoo logs for a currency
  # exchange. An exchange only converts cash inside the moomoo account, so it
  # stays a plain funds movement even when one side is an investment account,
  # a manual one the user linked to a cash row (see
  # MoomooAccount::TradeSettlements.keep_funds_movement!).
  def self.exchange?(transfer)
    [ transfer.inflow_transaction, transfer.outflow_transaction ].all? do |transaction|
      transaction.entry.source == "moomoo" && transaction.entry.external_id.to_s.start_with?(EXTERNAL_ID_PREFIX) &&
        transaction.investment_activity_label == "Exchange"
    end
  end

  def initialize(moomoo_account)
    @moomoo_account = moomoo_account
    @skipped = Hash.new(0)
  end

  # Each row becomes a transaction in the currency its running balance is
  # kept in ("Balance: 12.34 USD"). In an account split by currency, the rows
  # go to their currency's cash account (see MoomooAccount#cash_log_row_for),
  # and a currency exchange between two linked ones becomes a transfer.
  def process
    return { transactions: 0, skipped: 0 } unless account.present?

    imported = moomoo_account.cash_log_rows.count { |row| import_row(row) }
    link_exchanges if moomoo_account.split_by_currency?
    log_skipped
    { transactions: imported, skipped: @skipped.values.sum }
  end

  private

    attr_reader :moomoo_account

    def account
      @account ||= moomoo_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def import_row(row)
      rule = RULES.find { |pattern, _| pattern.match?(row["transaction_name"].to_s) }&.last
      return skip(:unknown_kind) if rule.nil?
      return skip(:covered_elsewhere) if rule == :skip

      change = parse_amount(row["cash_change"])
      return skip(:bad_amount) unless change&.nonzero?

      currency = cash_log_currency(row)
      return skip(:no_currency) unless currency

      date = row_date(row["created_time"])
      return skip(:bad_time) unless date
      return skip(:digest) if row["digest"].blank?

      import_adapter.import_transaction(
        external_id: cash_log_external_id(row),
        amount: -change,
        currency: currency,
        date: date,
        name: row_name(row),
        source: "moomoo",
        kind: rule[:kind],
        investment_activity_label: activity_label(rule[:label]),
        allow_heuristic_matching: false
      )
      true
    end

    def activity_label(label)
      label unless account.depository? && CASH_ACCOUNT_UNLABELED.include?(label)
    end

    def cash_log_external_id(row)
      "#{EXTERNAL_ID_PREFIX}#{row['digest']}"
    end

    # moomoo logs an exchange as one row per currency, at the same time and
    # with opposite signs. Once both rows are in their currencies' accounts,
    # they are linked as a transfer from the currency sold to the one bought,
    # unless the user unlinked them. It stays a plain funds movement (see
    # .exchange?).
    def link_exchanges
      exchange_pairs.each do |sold, bought|
        outflow = imported_transaction(sold)
        inflow = imported_transaction(bought)
        next unless outflow && inflow && account.in?([ outflow.entry.account, inflow.entry.account ])

        existing = outflow.transfer || inflow.transfer
        if existing
          keep_funds_movement(existing) if existing.inflow_transaction_id == inflow.id && existing.outflow_transaction_id == outflow.id
          next
        end
        next if RejectedTransfer.exists?(inflow_transaction_id: inflow.id, outflow_transaction_id: outflow.id)

        keep_funds_movement(Transfer.create!(inflow_transaction: inflow, outflow_transaction: outflow, status: "confirmed"))
      rescue => e
        DebugLogEntry.capture(
          category: "sync",
          level: "warn",
          message: "MoomooAccount::CashLogsProcessor - Failed to link a currency exchange as a transfer: #{e.message}",
          source: "moomoo",
          provider_key: "moomoo",
          family: moomoo_account.moomoo_item.family,
          account_provider: moomoo_account.account_provider,
          metadata: { moomoo_account_id: moomoo_account.id }
        )
      end
    end

    def keep_funds_movement(transfer)
      MoomooAccount::TradeSettlements.keep_funds_movement!(transfer) if self.class.exchange?(transfer)
    end

    # [sold, bought] rows of each exchange: a pair at one time, one row going
    # out and one coming in, in two currencies.
    def exchange_pairs
      Array(moomoo_account.source_account.raw_cash_logs_payload)
        .select { |row| row.is_a?(Hash) && row["transaction_name"].to_s.match?(EXCHANGE) }
        .group_by { |row| row["created_time"].to_s }
        .filter_map do |_time, rows|
          next unless rows.size == 2

          sold, bought = rows.sort_by { |row| parse_amount(row["cash_change"]) || 0 }
          next unless parse_amount(sold["cash_change"])&.negative? && parse_amount(bought["cash_change"])&.positive?
          next if cash_log_currency(sold) == cash_log_currency(bought)

          [ sold, bought ]
        end
    end

    # The row's transaction in the linked account that takes its currency's
    # cash log.
    def imported_transaction(row)
      target_account = moomoo_account.cash_log_row_for(cash_log_currency(row))&.current_account
      return nil unless target_account

      target_account.entries.find_by(source: "moomoo", external_id: cash_log_external_id(row), entryable_type: "Transaction")&.entryable
    end

    # moomoo writes amounts with a sign and thousands separators ("+1,400.00").
    def parse_amount(value)
      parse_decimal(value.to_s.delete(","))
    end

    def row_date(value)
      zone = ActiveSupport::TimeZone[FIRM_TIME_ZONES.fetch(moomoo_account.security_firm.to_s, "UTC")]
      TIME_FORMATS.each do |format|
        return zone.strptime(value.to_s, format).to_date
      rescue ArgumentError
        next
      end
      nil
    end

    def row_name(row)
      subject = row["symbol"].to_s.match?(/\A\d+\z/) ? row["stock_name"] : row["symbol"]
      [ row["transaction_name"], subject.presence ].compact.join(" ").strip
    end

    def skip(reason)
      @skipped[reason] += 1
      false
    end

    def log_skipped
      unknown = @skipped.slice(:unknown_kind, :bad_amount, :no_currency, :bad_time, :digest)
      return if unknown.values.sum.zero?

      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "MoomooAccount::CashLogsProcessor - Skipped cash log rows Sure could not read",
        source: "moomoo",
        provider_key: "moomoo",
        family: moomoo_account.moomoo_item.family,
        account_provider: moomoo_account.account_provider,
        metadata: { moomoo_account_id: moomoo_account.id, skipped: unknown }
      )
    end
end
