require "csv"

# Imports contributions or equity grant vests from a CSV the user uploads.
# Headers are matched loosely (case, spaces and common synonyms), so exports
# from most brokers work once their columns are named sensibly.
class InvestmentCsvImport
  Result = Data.define(:created, :skipped, :errors)

  MAX_ROWS = 5_000

  CONTRIBUTION_HEADERS = {
    date: %w[date transaction_date trade_date posted_date],
    amount: %w[amount value contribution net_amount],
    kind: %w[kind type source contribution_type],
    description: %w[description memo note notes],
    principal_amount: %w[principal principal_amount cost_basis]
  }.freeze

  GRANT_HEADERS = {
    grant_identifier: %w[grant_id grant grant_identifier award_id award_number],
    ticker: %w[ticker symbol],
    grant_type: %w[grant_type award_type],
    grant_date: %w[grant_date award_date],
    total_units: %w[total_units granted_units units_granted grant_units],
    vest_date: %w[vest_date vesting_date release_date transaction_date],
    units: %w[units quantity vest_units vested_units shares],
    units_withheld: %w[units_withheld withheld shares_withheld units_sold_for_taxes],
    net_proceeds: %w[net_proceeds proceeds net_cash]
  }.freeze

  KIND_SYNONYMS = {
    "employee" => "contribution", "deposit" => "contribution", "contribution" => "contribution",
    "employer" => "employer_contribution", "match" => "employer_contribution", "company_match" => "employer_contribution",
    "employer_contribution" => "employer_contribution", "rollover" => "rollover",
    "transfer_in" => "transfer_in", "transfer_out" => "transfer_out", "transfer" => "transfer_in",
    "withdrawal" => "withdrawal", "distribution" => "withdrawal"
  }.freeze

  attr_reader :account, :content, :kind, :default_ticker

  def initialize(account:, content:, kind:, default_ticker: nil)
    @account = account
    @content = content.to_s.sub(/\A\xEF\xBB\xBF/, "")
    @kind = kind.to_s
    @default_ticker = default_ticker
  end

  def import!
    rows = CSV.parse(content, headers: true)
    raise ArgumentError, I18n.t("investment_csv_import.too_many_rows", max: MAX_ROWS) if rows.size > MAX_ROWS

    created = 0
    skipped = 0
    errors = []

    ActiveRecord::Base.transaction do
      rows.each_with_index do |row, index|
        values = map_row(row, kind == "contributions" ? CONTRIBUTION_HEADERS : GRANT_HEADERS)
        ok = kind == "contributions" ? import_contribution(values) : import_vest(values)
        ok ? created += 1 : skipped += 1
      rescue ActiveRecord::RecordInvalid, ArgumentError => e
        skipped += 1
        errors << I18n.t("investment_csv_import.row_error", row: index + 2, message: e.message)
      end
    end

    Result.new(created: created, skipped: skipped, errors: errors.first(10))
  rescue CSV::MalformedCSVError => e
    raise ArgumentError, I18n.t("investment_csv_import.malformed", message: e.message)
  end

  private
    def map_row(row, spec)
      normalized = row.to_h.transform_keys { |key| key.to_s.strip.downcase.gsub(/[^a-z0-9]+/, "_").delete_suffix("_") }
      spec.transform_values { |names| names.lazy.map { |name| normalized[name] }.find(&:present?) }
    end

    def import_contribution(values)
      date = parse_date(values[:date])
      amount = parse_number(values[:amount])
      return false if date.nil? || amount.nil? || amount.zero?

      kind = KIND_SYNONYMS[values[:kind].to_s.strip.downcase.gsub(/[^a-z]+/, "_")] || (amount.negative? ? "withdrawal" : "contribution")
      account.account_contributions.create!(
        date: date, amount: amount, kind: kind, description: values[:description].to_s.first(255).presence,
        principal_amount: parse_number(values[:principal_amount]), source: "csv", currency: account.currency
      )
    end

    def import_vest(values)
      ticker = values[:ticker].presence || default_ticker
      vest_date = parse_date(values[:vest_date])
      units = parse_number(values[:units])
      raise ArgumentError, I18n.t("investment_csv_import.ticker_missing") if ticker.blank?
      return false if vest_date.nil? || units.nil? || units <= 0

      grant = if values[:grant_identifier].present?
        account.equity_grants.find_or_initialize_by(grant_identifier: values[:grant_identifier].strip)
      else
        account.equity_grants.find_or_initialize_by(ticker: ticker.upcase, grant_date: parse_date(values[:grant_date]))
      end
      grant.ticker = ticker
      grant.grant_type = values[:grant_type].to_s.downcase.presence_in(EquityGrant::GRANT_TYPES) || grant.grant_type || "rsu"
      grant.grant_date ||= parse_date(values[:grant_date])
      grant.total_units ||= parse_number(values[:total_units])
      grant.source = "csv" if grant.new_record?
      grant.save!

      vest = grant.vests.find_or_initialize_by(vest_date: vest_date)
      vest.update!(units: units, units_withheld: parse_number(values[:units_withheld]) || vest.units_withheld,
                   net_proceeds: parse_number(values[:net_proceeds]) || vest.net_proceeds,
                   source: vest.new_record? ? "csv" : vest.source)
    end

    def parse_date(value)
      return nil if value.blank?

      text = value.to_s.strip
      [ "%Y-%m-%d", "%m/%d/%Y", "%b-%d-%Y", "%d-%b-%Y", "%b %d, %Y", "%m/%d/%y" ].each do |format|
        return Date.strptime(text, format)
      rescue ArgumentError
        next
      end
      nil
    end

    def parse_number(value)
      return nil if value.blank?

      text = value.to_s.strip
      negative = text.start_with?("(") && text.end_with?(")") || text.start_with?("-")
      digits = text.gsub(/[^\d.]/, "")
      return nil if digits.blank?

      number = BigDecimal(digits)
      negative ? -number : number
    rescue ArgumentError
      nil
    end
end
