require "csv"

# Imports vests from a CSV, one row per vest, grouping them into grants by
# grant ID (or by ticker and grant date; a row needs one or the other). Headers are matched loosely (case,
# spaces and common synonyms). Importing the same file again updates the same
# vests rather than adding new ones.
class EquityGrant::CsvImport
  Result = Data.define(:created, :skipped, :errors)

  MAX_ROWS = 5_000

  HEADERS = {
    grant_identifier: %w[grant_id grant grant_identifier award_id award_number],
    ticker: %w[ticker symbol],
    grant_type: %w[grant_type award_type],
    grant_date: %w[grant_date award_date],
    total_units: %w[total_units granted_units units_granted grant_units],
    strike_price: %w[strike_price exercise_price strike],
    vest_date: %w[vest_date vesting_date release_date],
    units: %w[units quantity vest_units vested_units shares],
    units_withheld: %w[units_withheld withheld shares_withheld units_sold_for_taxes],
    net_proceeds: %w[net_proceeds proceeds net_cash]
  }.freeze

  # Unambiguous formats, tried after ISO dates and the family's own format.
  FALLBACK_DATE_FORMATS = [ "%b-%d-%Y", "%d-%b-%Y", "%b %d, %Y", "%d %b %Y" ].freeze

  attr_reader :account, :content, :default_ticker, :date_format

  def initialize(account:, content:, default_ticker: nil)
    @account = account
    @content = content.to_s.sub(/\A\xEF\xBB\xBF/, "")
    @default_ticker = default_ticker
    @date_format = account.family.date_format
  end

  def import!
    rows = CSV.parse(content, headers: true)
    raise ArgumentError, I18n.t("equity_grants.csv_import.too_many_rows", max: MAX_ROWS) if rows.size > MAX_ROWS

    created = 0
    skipped = 0
    errors = []

    ActiveRecord::Base.transaction do
      rows.each_with_index do |row, index|
        import_vest(map_row(row)) ? created += 1 : skipped += 1
      rescue ActiveRecord::RecordInvalid, ArgumentError => e
        skipped += 1
        errors << I18n.t("equity_grants.csv_import.row_error", row: index + 2, message: e.message)
      end
    end

    Result.new(created: created, skipped: skipped, errors: errors.first(10))
  rescue CSV::MalformedCSVError => e
    raise ArgumentError, I18n.t("equity_grants.csv_import.malformed", message: e.message)
  end

  private
    def map_row(row)
      normalized = row.to_h.transform_keys { |key| key.to_s.strip.downcase.gsub(/[^a-z0-9]+/, "_").delete_suffix("_") }
      HEADERS.transform_values { |names| names.lazy.map { |name| normalized[name] }.find(&:present?) }
    end

    def import_vest(values)
      ticker = values[:ticker].presence || default_ticker
      vest_date = parse_date(values[:vest_date])
      units = parse_number(values[:units])
      raise ArgumentError, I18n.t("equity_grants.csv_import.ticker_missing") if ticker.blank?
      raise ArgumentError, I18n.t("equity_grants.csv_import.date_unreadable", value: values[:vest_date]) if values[:vest_date].present? && vest_date.nil?
      return false if vest_date.nil? || units.nil? || units <= 0

      if values[:grant_identifier].blank? && parse_date(values[:grant_date]).nil?
        raise ArgumentError, I18n.t("equity_grants.csv_import.grant_key_missing")
      end

      grant = find_or_build_grant(values, ticker)
      grant.ticker = ticker
      grant.grant_type = values[:grant_type].to_s.downcase.presence_in(EquityGrant::GRANT_TYPES) || grant.grant_type || "rsu"
      grant.grant_date ||= parse_date(values[:grant_date])
      grant.total_units ||= parse_number(values[:total_units])
      grant.strike_price ||= parse_number(values[:strike_price])
      grant.source = "csv" if grant.new_record?
      grant.save!

      vest = grant.vests.find_or_initialize_by(vest_date: vest_date)
      vest.update!(
        units: units,
        units_withheld: parse_number(values[:units_withheld]) || vest.units_withheld,
        net_proceeds: parse_number(values[:net_proceeds]) || vest.net_proceeds,
        source: vest.new_record? ? "csv" : vest.source
      )
    end

    def find_or_build_grant(values, ticker)
      identifier = values[:grant_identifier].to_s.strip.presence
      if identifier
        account.equity_grants.find_or_initialize_by(grant_identifier: identifier)
      else
        account.equity_grants.find_or_initialize_by(grant_identifier: nil, ticker: ticker.to_s.strip.upcase, grant_date: parse_date(values[:grant_date]))
      end
    end

    def parse_date(value)
      return nil if value.blank?

      text = value.to_s.strip
      return Date.iso8601(text) if text.match?(/\A\d{4}-\d{2}-\d{2}\z/)

      [ date_format, *FALLBACK_DATE_FORMATS ].compact.each do |format|
        return Date.strptime(text, format)
      rescue ArgumentError
        next
      end
      nil
    rescue ArgumentError
      nil
    end

    # Reads "1,234.56", "1.234,56", "12,5", "(300.00)" and "-300". The last of
    # "," or "." is the decimal separator when both appear. A single "," is a
    # decimal comma unless exactly three digits follow it ("1,234").
    def parse_number(value)
      return nil if value.blank?

      text = value.to_s.strip
      negative = (text.start_with?("(") && text.end_with?(")")) || text.include?("-")
      text = text.gsub(/[^\d.,]/, "")
      return nil if text.blank?

      if text.include?(",") && text.include?(".")
        decimal = text.rindex(",") > text.rindex(".") ? "," : "."
        text = text.delete(decimal == "," ? "." : ",").tr(",", ".")
      elsif text.count(",") == 1 && !text.match?(/,\d{3}\z/)
        text = text.tr(",", ".")
      else
        text = text.delete(",")
      end

      number = BigDecimal(text)
      negative ? -number : number
    rescue ArgumentError
      nil
    end
end
