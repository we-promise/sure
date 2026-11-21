# A bank statement's transactions, period and balances, from every page, batched by
# Ai::Batch with no page limit.
#
# #checks says, without knowing the answer, whether an extraction looks right. On every recorded
# extraction they passed all 14 right ones and failed all 12 wrong ones:
# - reconciles: the opening balance plus every row makes the closing balance. It catches
#   missing, merged, invented and sign-flipped rows, not dates. The balances come from the text
#   (#4054's parser) when it found them, the model's otherwise, since models write figures to fit.
#   nil when neither has both: the extraction is flagged as unchecked, and no other way of reading
#   would do better;
# - amounts_in_source: every amount appears in the text the model read (the text layer or an OCR
#   transcription); nil when it read images or the PDF;
# - dates_anchored: the share of rows whose date is the last date printed within DATE_WINDOW
#   characters before that row's amount. Right extractions scored 0.62-0.77, wrong dates under
#   0.2. A heuristic tuned on two statements, not a rule; nil without text;
# - complete: false when pages were skipped (no route could read them) or are still pending
#   after an outage, since rows missing from both sides can still reconcile; nil when not known.
# Rows with a zero amount ("Balance brought forward") are ignored. A period check was dropped:
# models write the period to fit their dates.
class Ai::Generations::ExtractBankStatement < Ai::Generation
  include Ai::PdfReading::Pages

  prompt "extract_bank_statement"
  schema_name "bank_statement"

  DATE_WINDOW = 120
  MIN_DATES_ANCHORED = 0.5
  DATE_FORMATS = %w[%m/%d %-m/%-d %d/%m %-d/%-m %d.%m %-d.%-m %-d%B %-d%b %B%-d %b%-d %Y-%m-%d].freeze
  # strftime's %B/%b are English; statements use whichever locale the bank prints. Build the
  # month names once from Rails' locale data instead of keeping an English-only list.
  LOCALIZED_MONTH_NAMES = I18n.available_locales.each_with_object({}) do |locale, names|
    %w[month_names abbr_month_names].each do |key|
      month_names = I18n.t("date.#{key}", locale:, default: nil)
      next unless month_names.is_a?(Array)

      month_names.each_with_index do |name, month|
        next if month.zero? || name.blank?

        (names[month] ||= []) << name.downcase
      end
    end
  end.transform_values(&:uniq).freeze

  schema({
    type: "object",
    properties: {
      bank_name: NULLABLE_STRING, account_holder: NULLABLE_STRING, account_number: NULLABLE_STRING, currency: NULLABLE_STRING,
      statement_period: {
        type: %w[object null],
        properties: { start_date: NULLABLE_STRING, end_date: NULLABLE_STRING },
        required: %w[start_date end_date],
        additionalProperties: false
      },
      opening_balance: NULLABLE_NUMBER,
      closing_balance: NULLABLE_NUMBER,
      transactions: {
        type: "array",
        items: {
          type: "object",
          properties: {
            date: { type: "string", description: "YYYY-MM-DD" },
            description: { type: "string" },
            amount: { type: "number", description: "Negative for money out, positive for money in." },
            reference: NULLABLE_STRING,
            category: NULLABLE_STRING
          },
          required: %w[date description amount reference category],
          additionalProperties: false
        }
      }
    },
    required: %w[bank_name account_holder account_number currency statement_period opening_balance closing_balance transactions],
    additionalProperties: false
  }.freeze)

  required :date, :amount
  aliases transactions: %w[rows entries], description: %w[name merchant]

  Checks = Data.define(:reconciles, :amounts_in_source, :dates_anchored, :complete) do
    def initialize(reconciles:, amounts_in_source:, dates_anchored:, complete: nil) = super

    # From the hash PdfImport#extraction_checks stores.
    def self.from_h(hash) = new(**members.index_with { hash.to_h.symbolize_keys[_1] })

    # The names of the checks that failed. `balances` fails when there were none to reconcile
    # with; the other two pass when there was no text to check against (nil).
    def failed = results.reject { |_, passed| passed }.keys

    def passed? = failed.empty?

    # Whether reading the statement another way could pass more: not when all that failed is
    # balances the statement doesn't print.
    def worth_another_way? = (failed - %i[balances]).any?

    # How many checks passed, to pick the best of several failing extractions.
    def score = results.count { |_, passed| passed }

    # `settled`: Auto stopped here, so PdfImport.last_passing_way learns from it.
    def to_h = super.merge(passed: passed?, settled: !worth_another_way?)

    private
      def results
        { balances: !reconciles.nil?, reconciles: reconciles != false, amounts_in_source: amounts_in_source != false,
          dates_anchored: dates_anchored.nil? || dates_anchored >= MIN_DATES_ANCHORED, complete: complete != false }
      end
  end

  # Batches in document order: rows concatenated, the first row of a batch dropped when it repeats
  # the last row of the batch before (#846: a chunk boundary can cut a table, and both sides read
  # the cut row), the first batch's opening figures and the last batch's closing ones. Equal rows
  # anywhere else are two purchases, and both are kept.
  def merge_values(values)
    # A run with every slice skipped is not an empty statement: no model answered. Fail the way
    # so Auto can try another, and keep an explicit empty transactions list from a real answer.
    raise Ai::Error::InvalidOutput, "no extraction answered" if values.empty?

    batches = values.map { Array(_1[:transactions]) }
    kept = batches.each_with_index.flat_map do |rows, i|
      previous = i.positive? ? batches[i - 1].last : nil
      rows.first && previous && same_row?(rows.first, previous) ? rows.drop(1) : rows
    end

    first = ->(key) { values.lazy.map { _1[key] }.find(&:present?) }
    last = ->(key) { values.reverse.lazy.map { _1[key] }.find(&:present?) }
    periods = values.filter_map { _1[:statement_period] }
    {
      bank_name: first.(:bank_name), account_holder: first.(:account_holder), account_number: first.(:account_number),
      currency: first.(:currency), opening_balance: first.(:opening_balance), closing_balance: last.(:closing_balance),
      statement_period: { start_date: periods.lazy.map { _1[:start_date] }.find(&:present?),
                          end_date: periods.reverse.lazy.map { _1[:end_date] }.find(&:present?) },
      transactions: kept
    }
  end

  def same_row?(row, other) = row.values_at(:date, :amount, :description, :reference) == other.values_at(:date, :amount, :description, :reference)

  # source: the text the model read, or nil for images and the PDF. balances: the opening and
  # closing balances read from the text layer (AccountStatement::TextMetadataParser), when found.
  def self.checks(value, source: nil, balances: {})
    rows = transactions(value)
    period = value[:statement_period]
    dated = rows.map { _1.merge(date: normal_date(_1[:date], period:)) }
    invalid_date = dated.any? { _1[:date].nil? }
    opening = balances[:opening_balance] || value[:opening_balance]
    closing = balances[:closing_balance] || value[:closing_balance]
    reconciles = unless opening.nil? || closing.nil?
      rows.any? && (opening.to_d + rows.sum { _1[:amount].to_d }).round(2) == closing.to_d.round(2)
    end
    # Whitespace goes, so "1 February" reads as "1february", except between two digits, where it
    # keeps the numbers apart: "120.00 -100.00" is two amounts, neither of them 20.00.
    text = source&.downcase&.gsub(/(?<=\d)\s+(?=\d)/, "|")&.gsub(/\s+/, "")
    return Checks.new(reconciles:, amounts_in_source: nil, dates_anchored: invalid_date ? 0.0 : nil) if text.blank? || rows.empty?

    dates = dated.flat_map { |row| printed_dates(row[:date]).map { [ _1, row[:date] ] } }.uniq
                 .map { |form, date| [ form_pattern(form), form.length, date ] }
    Checks.new(reconciles:, amounts_in_source: dated.all? { |row| text.match?(amount_pattern(row[:amount])) },
               dates_anchored: invalid_date ? 0.0 : (dated.count { date_anchored?(_1, dates, text) } / dated.size.to_f).round(2))
  end

  # The value in the shape PdfImport#extracted_data holds.
  def self.statement(value)
    period = value[:statement_period]
    {
      transactions: transactions(value).map do |row|
        { date: normal_date(row[:date], period:), amount: row[:amount]&.to_f, name: row[:description], category: row[:category], notes: row[:reference] }
      end,
      period: { start_date: normal_date(value.dig(:statement_period, :start_date)), end_date: normal_date(value.dig(:statement_period, :end_date)) },
      account_holder: value[:account_holder], account_number: value[:account_number], bank_name: value[:bank_name],
      currency: value[:currency], opening_balance: value[:opening_balance], closing_balance: value[:closing_balance]
    }
  end

  # The rows, without zero-amount lines ("Balance brought forward"), which aren't transactions.
  def self.transactions(value) = Array(value[:transactions]).reject { _1[:amount].to_f.zero? }

  class << self
    private
      # A batch can print "1 February" or "02/01" without the year. Resolve it against the whole
      # statement period: for a December-to-January statement, "1 January" belongs to the closing
      # year, not the opening one. When the period doesn't identify a single year for the date,
      # leave it unresolved so the checks flag it rather than guessing.
      def normal_date(text, period: nil)
        string = text.to_s.strip
        return if string.blank?
        return Date.parse(string).iso8601 if string.match?(/(?<!\d)\d{4}(?!\d)/)

        year = year_for(string, period)
        return if year.nil?

        Date.parse("#{string} #{year}").iso8601
      rescue ArgumentError
        nil
      end

      def year_for(string, period)
        bounds = [ period&.[](:start_date), period&.[](:end_date) ].filter_map { normal_date(_1) }.map { Date.iso8601(_1) }.uniq
        years = bounds.map(&:year).uniq
        return years.first if years.size == 1
        return if bounds.size != 2

        matches = years.filter_map { |year| Date.parse("#{string} #{year}") rescue nil }
                       .select { |date| date.between?(*bounds.minmax) }.uniq
        matches.first.year if matches.size == 1
      end

      # Some occurrence of the row's amount has, as the last date printed in the DATE_WINDOW
      # characters before it, the row's own date. `dates`: every row's printed forms, as
      # [form_pattern, the form's length, the row's date]. Where two forms end at the same place,
      # the longer one is the printed date.
      def date_anchored?(row, dates, text)
        positions(text, amount_pattern(row[:amount])).any? do |at|
          before = text[[ at - DATE_WINDOW, 0 ].max...at]
          dates.filter_map { |pattern, length, date| (index = before.rindex(pattern)) && [ index, length, date ] }
               .max_by { |index, length, _| [ index, length ] }&.last == row[:date]
        end
      end

      # Date forms must not be part of a longer number ("1february" isn't the
      # "11february" printed on the row), but a letter-form may sit beside other
      # letters.
      def form_pattern(form)
        pattern = Regexp.escape(form)
        pattern = "(?<!\\d)#{pattern}" if form.match?(/\A\d/)
        pattern = "#{pattern}(?!\\d)" if form.match?(/\d\z/)
        Regexp.new(pattern)
      end

      def positions(text, pattern) = text.enum_for(:scan, pattern).map { Regexp.last_match.begin(0) }

      # The amount as a whole number in the text, not part of a longer one: "20.00" isn't in
      # "120.00", "1,020.00" or "20.005"; after a word or a comma ("Ford, 50.00") it is. Whole
      # groups of three digits after a space may be the tail of a space-grouped number: "234,56"
      # isn't in "1 234,56".
      def amount_pattern(amount)
        whole = format("%.2f", amount.to_f.abs).split(".").first
        group_tail = "(?<!\\d\\|)" if whole.length % 3 == 0
        /(?<!\d)(?<!\d[.,])#{group_tail}(?:#{printed_amounts(amount).map { Regexp.escape(_1) }.join("|")})(?!\d)/
      end

      # 2575.0 as "2575.00", "2,575.00" or "1.234,56", with spaces between digits normalized to
      # "|" upstream; 0.26 also as ".26" or ",26". Dot-decimal forms stay first.
      def printed_amounts(amount)
        whole, cents = format("%.2f", amount.to_f.abs).split(".")
        grouped = ->(separator) { whole.gsub(/(?<=\d)(?=(\d{3})+\z)/, separator) }
        [ "#{whole}.#{cents}", "#{grouped.call(',')}.#{cents}", "#{grouped.call('|')}.#{cents}", (".#{cents}" if whole == "0"),
          "#{whole},#{cents}", "#{grouped.call('.')},#{cents}", "#{grouped.call('|')},#{cents}", (",#{cents}" if whole == "0") ].compact.uniq
      end

      # 2019-02-01 as "02/01", "2/1", "01/02", "05.01", "1february", "1feb", "5janvier"...
      def printed_dates(date)
        day = Date.iso8601(date.to_s)
        localized = LOCALIZED_MONTH_NAMES.fetch(day.month, []).flat_map { |name| [ "#{day.day}#{name}", "#{name}#{day.day}" ] }
        (DATE_FORMATS.map { day.strftime(_1).downcase } + localized).uniq
      rescue Date::Error
        []
      end
  end
end
