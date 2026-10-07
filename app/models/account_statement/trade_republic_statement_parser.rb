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
  MONTHS = {
    # Italian
    "gen" => 1, "feb" => 2, "mar" => 3, "apr" => 4, "mag" => 5, "giu" => 6,
    "lug" => 7, "ago" => 8, "set" => 9, "ott" => 10, "nov" => 11, "dic" => 12,
    # English
    "jan" => 1, "may" => 5, "jun" => 6, "jul" => 7, "aug" => 8, "sep" => 9,
    "sept" => 9, "oct" => 10, "dec" => 12,
    # German
    "mär" => 3, "märz" => 3, "mai" => 5, "juni" => 6, "juli" => 7, "okt" => 10, "dez" => 12,
    # French
    "janv" => 1, "févr" => 2, "fevr" => 2, "mars" => 3, "avr" => 4, "juin" => 6,
    "juil" => 7, "août" => 8, "aout" => 8, "déc" => 12,
    # Spanish
    "ene" => 1, "abr" => 4
  }.freeze
  DATE_TOKEN = /(\d{1,2})\s+([[:alpha:]]{3,5})\.?\s+(\d{4})/
  PERIOD_PATTERN = /#{DATE_TOKEN}\s*[-–]\s*#{DATE_TOKEN}/
  OPENING_BALANCE_HEADERS = [
    "saldo iniziale", "opening balance", "anfangssaldo", "solde initial", "saldo inicial"
  ].freeze
  AMOUNT_PATTERN = /(-?\d{1,3}(?:[.,\u00A0\u202F ]\d{3})*[.,]\d{2})[\u00A0 ]?€|€[\u00A0 ]?(-?\d{1,3}(?:[.,\u00A0\u202F ]\d{3})*[.,]\d{2})/
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
      month = MONTHS[month_name.downcase]
      return nil unless month

      date = Date.new(year.to_i, month, day.to_i)
      AccountStatement::MetadataDetector.reasonable_date?(date) ? date : nil
    rescue Date::Error
      nil
    end

    def parse_summary
      header_index = OPENING_BALANCE_HEADERS.filter_map { |header| @text.downcase.index(header) }.min
      return nil unless header_index

      amounts = @text[header_index..].scan(AMOUNT_PATTERN).first(4).map { |groups| parse_amount(groups.compact.first) }
      return nil if amounts.size < 4 || amounts.any?(&:nil?)

      opening, money_in, money_out, closing = amounts
      return nil unless (opening + money_in - money_out - closing).abs <= TOLERANCE

      [ opening, closing ]
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
