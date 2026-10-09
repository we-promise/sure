# frozen_string_literal: true

# Reads the period, IBAN and opening/closing balances from the text of a bank
# statement, without knowing which bank wrote it.
#
# - Period: the first date range in the text, e.g. "01 apr 2026 - 30 apr 2026",
#   "01.04.2026 – 30.04.2026", "2026-04-01 to 2026-04-30",
#   "April 1, 2026 to April 30, 2026" or "01st 1 2025 - 01st 7 2025".
# - Balances, in order of preference:
#   1. A summary table: the first four amounts after an opening-balance label,
#      kept only when opening + in - out == closing.
#   2. An opening and a closing balance, each on the same line as its label
#      ("Alter Kontostand 1.234,56 EUR" ... "Neuer Kontostand 2.000,00 EUR").
#   Both balances must carry the same currency.
#
# Month names and labels cover Italian, English, German, French, Spanish,
# Dutch and Portuguese. Anything it can't read is left blank, so a statement
# it doesn't understand falls back to filename detection.
class AccountStatement::TextMetadataParser
  Result = Data.define(
    :period_start_on, :period_end_on, :opening_balance, :closing_balance, :currency, :iban_last4, :balances_source
  )

  # Month tokens are matched in full, then on their first four and three
  # letters, which covers abbreviations ("Sept.", "févr.") and full names.
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

  ORDINAL = /(?:st|nd|rd|th)?/i
  MONTH_NAME = /[[:alpha:]]{3,10}/
  DATE_FORMATS = {
    iso: /(?<year>\d{4})-(?<month>\d{2})-(?<day>\d{2})/,
    numeric: %r{(?<day>\d{1,2})[./-](?<month>\d{1,2})[./-](?<year>\d{4})},
    ordinal_numeric: /(?<day>\d{1,2})(?:st|nd|rd|th)\s+(?<month>\d{1,2})\s+(?<year>\d{4})/i,
    day_month_name: /(?<day>\d{1,2})\.?#{ORDINAL}\s+(?<month_name>#{MONTH_NAME})\.?\s+(?<year>\d{4})/,
    month_name_day: /(?<month_name>#{MONTH_NAME})\.?\s+(?<day>\d{1,2})#{ORDINAL},?\s+(?<year>\d{4})/
  }.freeze
  DATE = Regexp.union(DATE_FORMATS.values.map { |format| Regexp.new(format.source.gsub(/\(\?<\w+>/, "(?:"), format.options) })
  RANGE_SEPARATOR = /\s*(?:[-–—]|\b(?:to|through|until|bis|al|au|tot|a|até|hasta)\b)\s*/i
  PERIOD_PATTERN = /(?<start>#{DATE})#{RANGE_SEPARATOR}(?<end>#{DATE})/
  # Annual statements span a year; anything longer isn't one period.
  MAX_PERIOD_DAYS = 400

  OPENING_LABELS = [
    "opening balance", "beginning balance", "starting balance", "initial balance", "previous balance",
    "balance brought forward", "saldo iniziale", "saldo precedente", "anfangssaldo", "alter kontostand",
    "alter saldo", "solde initial", "solde d'ouverture", "ancien solde", "solde précédent",
    "saldo inicial", "saldo anterior", "beginsaldo", "vorig saldo"
  ].freeze
  # "Carried forward" is left out: it is often a per-page subtotal.
  CLOSING_LABELS = [
    "closing balance", "ending balance", "final balance", "new balance", "saldo finale", "endsaldo",
    "neuer kontostand", "neuer saldo", "solde final", "solde de fermeture", "nouveau solde",
    "saldo final", "saldo atual", "eindsaldo", "nieuw saldo"
  ].freeze

  # Words may be split by spaces or dots: some PDFs extract "Saldo.iniziale".
  def self.label_pattern(labels)
    Regexp.union(labels.map { |label| /#{label.split.map { |word| Regexp.escape(word) }.join('[\s.]+')}/i })
  end

  OPENING_PATTERN = label_pattern(OPENING_LABELS)
  CLOSING_PATTERN = label_pattern(CLOSING_LABELS)
  BALANCE_LABEL_PATTERN = Regexp.union(OPENING_PATTERN, CLOSING_PATTERN)
  # The date a balance label is stated for: "Saldo iniziale al 01.07.2025",
  # "Alter Kontostand vom 31.03.2026", "Opening balance on 1 April 2026".
  LABEL_DATE = /\A[\s.:]*(?:(?:al|vom|am|as of|as at|at|on|du|au|del|op|em|per)\b)?[\s.:]*(?<date>#{DATE})/i

  # A number with two decimals ("1.944,58", "1,944.58", "1 944,58", "1'944.58")
  # that isn't part of a date such as 31.03.2026.
  AMOUNT_NUMBER = /(?<![\d.,])\d{1,3}(?:[.,'\u00A0\u202F ]\d{3})*[.,]\d{2}(?![\d]|[.,\/-]\d)/
  CURRENCY_TOKEN = /€|£|\$|\b[A-Z]{3}\b/
  # "1.234,56 €", "+1.234,56      €", "1.234,56 EUR", "-1.234,56 €", "€1,234.56",
  # "-€1,234.56", "€-1,234.56", "EUR 1.234,56" or a bare "1.234,56".
  AMOUNT_PATTERN = Regexp.union(
    /(?<prefix_sign>[-+])?(?<prefix_currency>#{CURRENCY_TOKEN})\p{Blank}*(?<inner_sign>[-+])?(?<prefix_number>#{AMOUNT_NUMBER})/,
    /(?<suffix_sign>[-+])?(?<suffix_number>#{AMOUNT_NUMBER})(?:\p{Blank}*(?<suffix_currency>#{CURRENCY_TOKEN}))?/
  )
  CURRENCY_SYMBOLS = { "€" => "EUR", "£" => "GBP" }.freeze
  # The rest of the line after "IBAN": one unspaced token, or the printed
  # groups of four ("DE89 3704 0044 0532 0130 00").
  IBAN_PATTERN = /IBAN[:\s]*([A-Z]{2}\d{2}[A-Z0-9 ]*)/
  TOLERANCE = BigDecimal("0.01")

  Amount = Data.define(:value, :currency)

  # currency: the statement's currency, used to read an ambiguous symbol
  # such as "$" when the statement is in a dollar currency.
  def self.parse(text, currency: nil)
    new(text, currency: currency).parse
  end

  def initialize(text, currency: nil)
    @text = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    @currency_hint = currency.to_s.upcase.presence
  end

  def parse
    period = parse_period
    balances, source = parse_balances
    return nil if period.nil? && balances.nil?

    Result.new(
      period_start_on: period&.first,
      period_end_on: period&.last,
      opening_balance: balances&.first&.value,
      closing_balance: balances&.last&.value,
      currency: balances&.first&.currency,
      iban_last4: parse_iban_last4,
      balances_source: source
    )
  end

  private

    # The dates next to the opening and closing balance belong to the
    # statement itself, so they win over the first date range in the text,
    # which can be a promotion ("dal 3 luglio 2024 al 30 giugno 2025").
    def parse_period
      label_period || range_period
    end

    def label_period
      opening_on = date_after_label(OPENING_PATTERN)
      closing_on = date_after_label(CLOSING_PATTERN)
      return nil unless opening_on && closing_on

      # A balance dated at a month end is the previous period's closing
      # ("Alter Kontostand vom 31.03.2026"), so the period starts the next day.
      start_on = opening_on == opening_on.end_of_month ? opening_on + 1 : opening_on
      valid_period(start_on, closing_on)
    end

    def range_period
      @text.to_enum(:scan, PERIOD_PATTERN).each do
        match = Regexp.last_match
        period = valid_period(parse_date(match[:start]), parse_date(match[:end]))
        return period if period
      end
      nil
    end

    def valid_period(start_on, end_on)
      return nil if start_on.nil? || end_on.nil? || end_on < start_on || (end_on - start_on) > MAX_PERIOD_DAYS

      [ start_on, end_on ]
    end

    def date_after_label(pattern)
      @text.each_line do |line|
        match = line.match(pattern)
        next unless match

        raw = line[match.end(0)..][LABEL_DATE, "date"]
        date = raw && parse_date(raw)
        return date if date
      end
      nil
    end

    def parse_date(raw)
      DATE_FORMATS.each_value do |format|
        match = raw.match(/\A#{format}\z/)
        next unless match

        month = match.names.include?("month") ? match[:month].to_i : month_number(match[:month_name])
        next unless month&.between?(1, 12)

        date = Date.new(match[:year].to_i, month, match[:day].to_i)
        return date if AccountStatement::MetadataDetector.reasonable_date?(date)
      rescue Date::Error
        next
      end
      nil
    end

    def month_number(name)
      token = name.to_s.downcase
      MONTHS[token] || MONTHS[token[0, 4]] || MONTHS[token[0, 3]]
    end

    def parse_balances
      summary = parse_summary_table
      return [ summary, "summary_table" ] if summary

      labelled = parse_labelled_balances
      return [ labelled, "labels" ] if labelled

      nil
    end

    def parse_summary_table
      header_index = @text =~ OPENING_PATTERN
      return nil unless header_index

      amounts = amounts_in(@text[header_index..]).first(4)
      return nil if amounts.size < 4

      opening, money_in, money_out, closing = amounts
      return nil unless (opening.value + money_in.value - money_out.value - closing.value).abs <= TOLERANCE

      same_currency(opening, closing)
    end

    def parse_labelled_balances
      opening = amount_after_label(OPENING_PATTERN)
      closing = amount_after_label(CLOSING_PATTERN)
      return nil unless opening && closing

      same_currency(opening, closing)
    end

    # The first amount after the label on its line, or on the next non-blank
    # line when the label stands alone ("Saldo finale al 30.09.2025", then
    # "+6.506,55 €"). A line with several labels is a table header whose next
    # line holds every column, so it never falls through.
    def amount_after_label(pattern)
      lines = @text.lines
      lines.each_with_index do |line, index|
        match = line.match(pattern)
        next unless match

        amount = amounts_in(line[match.end(0)..]).first
        return amount if amount
        next if line.scan(BALANCE_LABEL_PATTERN).size > 1

        following = lines[(index + 1)..].find { |candidate| candidate.strip.present? }
        amount = following && amounts_in(following).first
        return amount if amount
      end
      nil
    end

    def same_currency(opening, closing)
      return nil unless opening.currency == closing.currency

      [ opening, closing ]
    end

    def amounts_in(text)
      text.to_enum(:scan, AMOUNT_PATTERN).filter_map do
        match = Regexp.last_match
        value = parse_amount(match[:prefix_number] || match[:suffix_number])
        next unless value

        negative = [ match[:prefix_sign], match[:inner_sign], match[:suffix_sign] ].include?("-")
        Amount.new(value: negative ? -value : value, currency: resolve_currency(match[:prefix_currency] || match[:suffix_currency]))
      end
    end

    # Accepts "1.944,58" and "1,944.58": the last separator is the decimal one.
    def parse_amount(value)
      digits = value.to_s.delete(" '\u00A0\u202F")
      decimal_separator = digits[-3]
      integer_part, fraction = digits[0...-3], digits[-2..]
      return nil unless [ ",", "." ].include?(decimal_separator)

      BigDecimal("#{integer_part.delete(".,")}.#{fraction}")
    rescue ArgumentError
      nil
    end

    def resolve_currency(token)
      return nil if token.blank?
      return CURRENCY_SYMBOLS[token] if CURRENCY_SYMBOLS.key?(token)
      return dollar_hint if token == "$"

      Money::Currency.new(token).iso_code
    rescue Money::Currency::UnknownCurrencyError
      nil
    end

    def dollar_hint
      @currency_hint if @currency_hint && Money::Currency.new(@currency_hint).symbol == "$"
    rescue Money::Currency::UnknownCurrencyError
      nil
    end

    def parse_iban_last4
      tokens = @text[IBAN_PATTERN, 1].to_s.split(" ")
      iban = tokens.shift.to_s
      if iban.length == 4
        # Printed groups: keep the four-character ones, then a shorter final
        # group of digits, and stop before anything else on the line (a BIC).
        iban << tokens.shift while tokens.first&.match?(/\A[A-Z0-9]{4}\z/)
        iban << tokens.shift if tokens.first&.match?(/\A\d{1,3}\z/)
      end
      iban.match?(/\d{4}\z/) ? iban[-4..] : nil
    end
end
