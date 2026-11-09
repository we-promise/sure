# Monarch's two CSV exports, parsed: daily balances per account, and
# transactions. Also suggests a Sure type and closure for each account, which
# the person confirms before importing.
class MonarchImport::Exports
  BALANCE_COLUMNS = %w[Date Balance Account].freeze
  TRANSACTION_COLUMNS = %w[Date Merchant Category Account Amount Id].freeze
  STALE_AFTER_DAYS = 180

  Error = Class.new(StandardError)

  # Suggested settings for one Monarch account.
  Suggestion = Data.define(:name, :type, :closed, :last_activity, :latest_balance, :transactions_count, :balance_days, :first_date, :last_date)

  attr_reader :balances, :transactions

  # balances: { account name => { date => balance } }, skipping blank balances.
  # transactions: the transaction rows, pending ones included.
  def initialize(balances_csv:, transactions_csv: nil)
    @balances = parse_balances(balances_csv)
    @transactions = transactions_csv.present? ? parse_transactions(transactions_csv) : []
    raise Error, I18n.t("activerecord.errors.models.monarch_import.no_accounts") if account_names.empty?
  end

  def balances_only?
    transactions.empty?
  end

  def account_names
    (balances.keys | transactions.map { |row| row[:account] }).sort
  end

  def end_date
    @end_date ||= (balances.values.flat_map(&:keys) + transactions.map { |row| row[:date] }).max
  end

  def transactions_for(include_pending:)
    include_pending ? transactions : transactions.reject { |row| row[:pending] }
  end

  # Suggestions for every account, most recently active first.
  def suggestions
    @suggestions ||= begin
      dates_by_account = transactions.group_by { |row| row[:account] }.transform_values { |rows| rows.map { |row| row[:date] } }

      account_names.map do |name|
        suggest(name, balances.fetch(name, {}), dates_by_account.fetch(name, []))
      end.sort_by.with_index { |suggestion, index| [ -(suggestion.last_activity&.jd || 0), index ] }
    end
  end

  private
    def parse_balances(csv)
      rows = parse_csv(csv, BALANCE_COLUMNS, :balances)
      rows.each_with_object(Hash.new { |hash, key| hash[key] = {} }) do |row, balances|
        amount = parse_amount(row["Balance"])
        next if amount.nil?

        balances[parse_account(row["Account"])][parse_date(row["Date"])] = amount
      end.to_h { |name, history| [ name, history.sort.to_h ] }
    end

    def parse_transactions(csv)
      parse_csv(csv, TRANSACTION_COLUMNS, :transactions).map do |row|
        {
          id: row["Id"].to_s,
          date: parse_date(row["Date"]),
          account: parse_account(row["Account"]),
          amount: parse_amount(row["Amount"]),
          merchant: row["Merchant"].to_s.strip,
          original_statement: row["Original Statement"].to_s.strip,
          category: row["Category"].to_s.strip,
          notes: row["Notes"].to_s.strip,
          tags: row["Tags"].to_s.split(",").map(&:strip).reject(&:blank?),
          pending: row["Pending"].to_s.strip.casecmp?("true")
        }
      end
    end

    def parse_csv(csv, required, file)
      label = I18n.t("activerecord.errors.models.monarch_import.files.#{file}")
      text = csv.to_s.dup.force_encoding(Encoding::UTF_8).scrub.delete_prefix("\uFEFF")
      table = CSV.parse(text, headers: true)
      missing = required - table.headers.compact
      raise Error, I18n.t("activerecord.errors.models.monarch_import.missing_columns", file: label, columns: missing.join(", ")) if missing.any?

      table
    rescue CSV::MalformedCSVError => e
      raise Error, I18n.t("activerecord.errors.models.monarch_import.malformed_csv", file: label, error: e.message)
    end

    def parse_amount(value)
      raw = value.to_s.delete(",$").strip
      return if raw.empty?

      amount = BigDecimal(raw)
      raise ArgumentError unless amount.finite?

      amount
    rescue ArgumentError
      raise Error, I18n.t("activerecord.errors.models.monarch_import.invalid_number", value: value)
    end

    # Limited to the dates other imports accept, which also bounds how many
    # days a balance history can span.
    def parse_date(value)
      date = Date.iso8601(value.to_s)
      range = Import.reasonable_date_range
      unless range.cover?(date)
        raise Error, I18n.t("activerecord.errors.models.monarch_import.date_out_of_range", value: value, from: range.begin.iso8601, to: range.end.iso8601)
      end

      date
    rescue Date::Error
      raise Error, I18n.t("activerecord.errors.models.monarch_import.invalid_date", value: value)
    end

    def parse_account(value)
      value.to_s.strip.presence || raise(Error, I18n.t("activerecord.errors.models.monarch_import.blank_account"))
    end

    def suggest(name, history, transaction_dates)
      nonzero = history.values.reject(&:zero?)
      mostly_negative = nonzero.any? && nonzero.count(&:negative?) > nonzero.size / 2.0
      type = if mostly_negative
        transaction_dates.any? ? "CreditCard" : "Loan"
      elsif transaction_dates.any?
        "Depository"
      else
        "Investment"
      end

      last_activity = last_activity(history, transaction_dates)
      Suggestion.new(
        name: name,
        type: type,
        closed: last_activity.present? && (end_date - last_activity).to_i >= STALE_AFTER_DAYS,
        last_activity: last_activity,
        latest_balance: history.values.last,
        transactions_count: transaction_dates.size,
        balance_days: history.size,
        first_date: history.keys.first,
        last_date: history.keys.last
      )
    end

    # The last day the account's money moved: its latest transaction, or the
    # latest day its balance changed. Monarch keeps reporting a balance long
    # after an account stops changing, so the last balance date says little.
    def last_activity(history, transaction_dates)
      dates = history.keys
      last_change = dates.each_cons(2).select { |before, after| history[after] != history[before] }.map(&:last).last
      [ last_change, dates.first, *transaction_dates ].compact.max
    end
end
