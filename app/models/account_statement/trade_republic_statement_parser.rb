# frozen_string_literal: true

# Reads the period, IBAN and balance summary from the text of a Trade Republic
# account statement PDF ("Estratto conto" / "Kontoauszug" / "Account statement").
#
# The summary table lists, per product, the opening balance, money in, money
# out and closing balance. Text extractors order those cells differently, so
# the parser takes the first four amounts after the opening-balance header and
# only accepts them when opening + in - out == closing.
class AccountStatement::TradeRepublicStatementParser
  Result = Data.define(:period_start_on, :period_end_on, :opening_balance, :closing_balance, :currency, :iban_last4)

  INSTITUTION_PATTERN = /trade\s+republic/i
  # Month tokens are matched on their first four, then first three letters,
  # which covers abbreviations ("Sept.", "févr.") and full names ("Oktober").
  # Languages: Italian, English, German, French, Spanish, Dutch, Portuguese.
  MONTHS = {
    "jan" => 1, "gen" => 1, "ene" => 1, "janv" => 1,
    "feb" => 2, "fév" => 2, "fev" => 2, "févr" => 2, "fevr" => 2,
    "mar" => 3, "maa" => 3, "mär" => 3, "mrz" => 3, "mrt" => 3,
    "apr" => 4, "avr" => 4, "abr" => 4,
    "may" => 5, "mag" => 5, "mai" => 5, "mei" => 5,
    "jun" => 6, "giu" => 6, "juin" => 6,
    "jul" => 7, "lug" => 7, "juil" => 7,
    "aug" => 8, "ago" => 8, "aoû" => 8, "aou" => 8,
    "sep" => 9, "set" => 9,
    "oct" => 10, "ott" => 10, "okt" => 10, "out" => 10,
    "nov" => 11,
    "dec" => 12, "dic" => 12, "dez" => 12, "déc" => 12
  }.freeze
  DATE_TOKEN = /(\d{1,2})\.?\s+([[:alpha:]]{3,10})\.?\s+(\d{4})/
  PERIOD_PATTERN = /#{DATE_TOKEN}\s*[-–]\s*#{DATE_TOKEN}/
  # Where the summary table starts: its opening-balance column header, or the
  # summary section title for editions whose headers are split over lines.
  SUMMARY_MARKERS = [
    "saldo iniziale", "opening balance", "initial balance", "anfangssaldo",
    "solde initial", "saldo inicial", "beginsaldo",
    "estratto conto riassuntivo", "synthèse du relevé de compte"
  ].freeze
  AMOUNT_NUMBER = /\d{1,3}(?:[.,\u00A0\u202F ]\d{3})*[.,]\d{2}/
  # "1.234,56 €", "-1.234,56 €", "€1,234.56", "-€1,234.56" and "€-1,234.56".
  AMOUNT_PATTERN = Regexp.union(
    /(?<suffix_sign>-)?(?<suffix_number>#{AMOUNT_NUMBER})[\u00A0 ]?€/,
    /(?<prefix_sign>-)?€[\u00A0 ]?(?<inner_sign>-)?(?<prefix_number>#{AMOUNT_NUMBER})/
  )
  IBAN_PATTERN = /IBAN[:\s]+([A-Z]{2}\d{2}[A-Z0-9]{10,30})\b/
  TOLERANCE = BigDecimal("0.01")

  def self.parse(text)
    new(text).parse
  end

  def initialize(text)
    @text = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
  end

  def parse
    return nil unless @text.match?(INSTITUTION_PATTERN)

    period = parse_period
    summary = parse_summary
    return nil if period.nil? && summary.nil?

    Result.new(
      period_start_on: period&.first,
      period_end_on: period&.last,
      opening_balance: summary&.first,
      closing_balance: summary&.last,
      currency: summary ? "EUR" : nil,
      iban_last4: parse_iban_last4
    )
  end

  private

    def parse_period
      match = @text.match(PERIOD_PATTERN)
      return nil unless match

      start_on = build_date(match[1], match[2], match[3])
      end_on = build_date(match[4], match[5], match[6])
      return nil if start_on.nil? || end_on.nil? || end_on < start_on

      [ start_on, end_on ]
    end

    def build_date(day, month_name, year)
      month = month_number(month_name)
      return nil unless month

      date = Date.new(year.to_i, month, day.to_i)
      AccountStatement::MetadataDetector.reasonable_date?(date) ? date : nil
    rescue Date::Error
      nil
    end

    def month_number(name)
      token = name.downcase
      MONTHS[token] || MONTHS[token[0, 4]] || MONTHS[token[0, 3]]
    end

    def parse_summary
      downcased = @text.downcase
      header_index = SUMMARY_MARKERS.filter_map { |marker| downcased.index(marker) }.min
      return nil unless header_index

      amounts = amount_matches(@text[header_index..]).first(4).map { |match| signed_amount(match) }
      return nil if amounts.size < 4 || amounts.any?(&:nil?)

      opening, money_in, money_out, closing = amounts
      return nil unless (opening + money_in - money_out - closing).abs <= TOLERANCE

      [ opening, closing ]
    end

    def amount_matches(text)
      text.to_enum(:scan, AMOUNT_PATTERN).map { Regexp.last_match }
    end

    def signed_amount(match)
      number = parse_amount(match[:suffix_number] || match[:prefix_number])
      return nil unless number

      negative = match[:suffix_sign] || match[:prefix_sign] || match[:inner_sign]
      negative ? -number : number
    end

    # Accepts "1.944,58" and "1,944.58": the last separator is the decimal one.
    def parse_amount(value)
      digits = value.to_s.delete(" \u00A0\u202F")
      decimal_separator = digits[-3]
      integer_part, fraction = digits[0...-3], digits[-2..]
      return nil unless [ ",", "." ].include?(decimal_separator)

      BigDecimal("#{integer_part.delete(".,")}.#{fraction}")
    rescue ArgumentError
      nil
    end

    def parse_iban_last4
      iban = @text[IBAN_PATTERN, 1]
      iban&.match?(/\d{4}\z/) ? iban[-4..] : nil
    end
end
