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
# - An opening or closing balance may carry a CR or DR marker ("$435.88 CR").
#
# Both candidates are returned as printed, in `balance_readings`: amount,
# marker and currency token of each balance, and the kinds of account the
# summary table adds up as. .balances_for turns them into the balances for an
# account and a statement currency.
#
# Month names and labels cover Italian, English, German, French, Spanish,
# Dutch and Portuguese. Anything it can't read is left blank, so a statement
# it doesn't understand falls back to filename detection.
class AccountStatement::TextMetadataParser
  Result = Data.define(
    :period_start_on, :period_end_on, :iban_last4, :balance_readings
  )
  Balances = Data.define(:opening_balance, :closing_balance, :currency, :source)
  CLASSIFICATIONS = %w[asset liability].freeze

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
  # Full names in the same languages, for formats that match a month exactly.
  FULL_MONTHS = [
    %w[january gennaio januar janvier enero januari janeiro],
    %w[february febbraio februar février fevrier febrero februari fevereiro],
    %w[march marzo märz maerz mars maart março marco],
    %w[april aprile avril abril],
    %w[may maggio mai mayo mei maio],
    %w[june giugno juni juin junio junho],
    %w[july luglio juli juillet julio julho],
    %w[august agosto août aout augustus],
    %w[september settembre septembre septiembre setembro],
    %w[october ottobre oktober octobre octubre outubro],
    %w[november novembre noviembre novembro],
    %w[december dicembre dezember décembre decembre diciembre dezembro]
  ].each_with_index.flat_map { |names, index| names.map { |name| [ name, index + 1 ] } }.to_h.freeze

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
  RANGE_WORD = /(?:[-–—]|\b(?:to|through|until|bis|al|au|tot|a|até|hasta)\b)/i
  RANGE_SEPARATOR = /\s*#{RANGE_WORD}\s*/
  PERIOD_PATTERN = /(?<start>#{DATE})#{RANGE_SEPARATOR}(?<end>#{DATE})/
  # "3 Sep 21 - 1 Oct 21". Read only when no four-digit-year period is found.
  # The month must be a whole MONTHS or FULL_MONTHS token ("2 Marketing 21" is
  # not a date), and any space counts, as PDF extractors may emit
  # non-breaking ones.
  TWO_DIGIT_YEAR_DATE = /(?<day>\d{1,2})#{ORDINAL}[[:space:]]+(?<month_name>[[:alpha:]]+)\.?[[:space:]]+(?<year>\d{2})(?!\d)/
  TWO_DIGIT_YEAR = TWO_DIGIT_YEAR_DATE.source.gsub(/\(\?<\w+>/, "(?:")
  TWO_DIGIT_YEAR_PERIOD = /(?<start>#{TWO_DIGIT_YEAR})[[:space:]]*#{RANGE_WORD}[[:space:]]*(?<end>#{TWO_DIGIT_YEAR})/
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
  CURRENCY_MARK = /€|£|\$|\b[A-Z]{3}\b/
  # "1.234,56 €", "+1.234,56      €", "1.234,56 EUR", "-1.234,56 €", "€1,234.56",
  # "-€1,234.56", "€-1,234.56", "EUR 1.234,56" or a bare "1.234,56".
  # Either form may be followed, directly or after one space, by a CR or DR
  # marker: "$435.88 CR", "435.88Cr".
  AMOUNT_PATTERN = /
    (?:#{Regexp.union(
      /(?<prefix_sign>[-+])?(?<prefix_currency>#{CURRENCY_MARK})\p{Blank}*(?<inner_sign>[-+])?(?<prefix_number>#{AMOUNT_NUMBER})/,
      /(?<suffix_sign>[-+])?(?<suffix_number>#{AMOUNT_NUMBER})(?:\p{Blank}*(?<suffix_currency>#{CURRENCY_MARK}))?/
    )})
    (?:\p{Blank}?(?<side>(?i:cr|dr))\b)?
  /x
  SIDES = { "cr" => :credit, "dr" => :debit }.freeze
  CURRENCY_SYMBOLS = { "€" => "EUR", "£" => "GBP" }.freeze
  # The rest of the line after "IBAN": one unspaced token, or the printed
  # groups of four ("DE89 3704 0044 0532 0130 00").
  IBAN_PATTERN = /IBAN[:\s]*([A-Z]{2}\d{2}[A-Z0-9 ]*)/
  TOLERANCE = BigDecimal("0.01")

  # value carries only a "-" sign; currency is the token as printed ("$",
  # "EUR"); side is the CR/DR marker, if any.
  Amount = Data.define(:value, :currency, :side)
  BALANCE_FIELDS = %w[opening_balance closing_balance].freeze

  def self.parse(text)
    new(text).parse
  end

  # The balances `readings` give for an account of `classification` ("asset",
  # "liability", or nil when there is none) and a statement in `currency`:
  # the summary table when it adds up for that account (for either, with
  # none), otherwise the labelled balances, whichever first has both balances
  # in `currency`. A marked balance is its absolute value, negative for CR on
  # a liability or DR on an asset, unsigned with no account.
  def self.balances_for(readings, classification:, currency:)
    readings = readings.to_h
    table = readings["summary_table"]
    candidates = []
    candidates << [ "summary_table", table ] if table && (classification.nil? || Array(table["adds_up_as"]).include?(classification))
    candidates << [ "labels", readings["labels"] ] if readings["labels"]

    candidates.each do |source, pair|
      currencies = BALANCE_FIELDS.map { |field| resolve_currency(pair.dig(field, "currency"), currency) }
      next unless currencies.uniq.size == 1 && currencies.first.present?
      next if currency.present? && currencies.first != currency.to_s.upcase

      opening, closing = BALANCE_FIELDS.map do |field|
        signed_amount(BigDecimal(pair.dig(field, "amount")), pair.dig(field, "side")&.to_sym, classification)
      end
      return Balances.new(opening_balance: opening, closing_balance: closing, currency: currencies.first, source: source)
    end
    nil
  end

  # "$" is read as the statement's currency when that is a dollar currency.
  def self.resolve_currency(token, statement_currency)
    return nil if token.blank?
    return CURRENCY_SYMBOLS[token] if CURRENCY_SYMBOLS.key?(token)
    if token == "$"
      return Money::Currency.new(statement_currency).symbol == "$" ? statement_currency.to_s.upcase : nil
    end

    Money::Currency.new(token).iso_code
  rescue Money::Currency::UnknownCurrencyError, ArgumentError
    nil
  end

  def self.signed_amount(value, side, classification)
    return value unless SIDES.value?(side)

    negative = (side == :credit && classification == "liability") || (side == :debit && classification == "asset")
    negative ? -value.abs : value.abs
  end

  def initialize(text)
    @text = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
  end

  def parse
    period = parse_period
    readings = balance_readings
    return nil if period.nil? && readings.empty?

    Result.new(
      period_start_on: period&.first,
      period_end_on: period&.last,
      iban_last4: parse_iban_last4,
      balance_readings: readings
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
      first_period(PERIOD_PATTERN) { |raw| parse_date(raw) } ||
        first_period(TWO_DIGIT_YEAR_PERIOD) { |raw| parse_two_digit_year_date(raw) }
    end

    def first_period(pattern)
      @text.to_enum(:scan, pattern).each do
        match = Regexp.last_match
        period = valid_period(yield(match[:start]), yield(match[:end]))
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

    def parse_two_digit_year_date(raw)
      match = raw.match(/\A#{TWO_DIGIT_YEAR_DATE}\z/)
      token = match[:month_name].downcase
      month = MONTHS[token] || FULL_MONTHS[token]
      return nil unless month

      date = Date.new(2000 + match[:year].to_i, month, match[:day].to_i)
      date if AccountStatement::MetadataDetector.reasonable_date?(date)
    rescue Date::Error
      nil
    end

    def month_number(name)
      token = name.to_s.downcase
      MONTHS[token] || MONTHS[token[0, 4]] || MONTHS[token[0, 3]]
    end

    def balance_readings
      table, adds_up_as = parse_summary_table
      labelled = parse_labelled_balances

      readings = {}
      readings["summary_table"] = reading(table).merge("adds_up_as" => adds_up_as) if table
      readings["labels"] = reading(labelled) if labelled
      readings
    end

    def reading(pair)
      BALANCE_FIELDS.zip(pair).to_h do |field, amount|
        [ field, { "amount" => amount.value.to_s("F"), "side" => amount.side&.to_s, "currency" => amount.currency } ]
      end
    end

    def parse_summary_table
      header_index = @text =~ OPENING_PATTERN
      return nil unless header_index

      amounts = amounts_in(@text[header_index..]).first(4)
      return nil if amounts.size < 4

      adds_up_as = CLASSIFICATIONS.select { |classification| adds_up?(amounts, classification) }
      [ [ amounts.first, amounts.last ], adds_up_as ] if adds_up_as.any?
    end

    # Only the balances take their sign from a marker; the money in and out
    # columns are totals and are read as printed.
    def adds_up?(amounts, classification)
      opening, money_in, money_out, closing = amounts
      opening = self.class.signed_amount(opening.value, opening.side, classification)
      closing = self.class.signed_amount(closing.value, closing.side, classification)
      (opening + money_in.value - money_out.value - closing).abs <= TOLERANCE
    end

    def parse_labelled_balances
      opening = amount_after_label(OPENING_PATTERN)
      closing = amount_after_label(CLOSING_PATTERN)
      return nil unless opening && closing

      [ opening, closing ]
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

    def amounts_in(text)
      text.to_enum(:scan, AMOUNT_PATTERN).filter_map do
        match = Regexp.last_match
        value = parse_amount(match[:prefix_number] || match[:suffix_number])
        next unless value

        negative = [ match[:prefix_sign], match[:inner_sign], match[:suffix_sign] ].include?("-")
        Amount.new(
          value: negative ? -value : value,
          currency: match[:prefix_currency] || match[:suffix_currency],
          side: SIDES[match[:side]&.downcase]
        )
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
