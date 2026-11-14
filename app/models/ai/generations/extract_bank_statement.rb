# A bank statement's transactions, period and balances, from every page, batched by
# Ai::Batch with no page limit. Replaces Provider::{Openai,Anthropic}::BankStatementExtractor.
#
# #checks says, without knowing the answer, whether an extraction looks right. On every recorded
# extraction they passed all 14 right ones and failed all 12 wrong ones:
# - reconciles: the opening balance plus every row makes the closing balance. It catches
#   missing, merged, invented and sign-flipped rows, not dates. The balances come from the text
#   (#4054's parser) when it found them, the model's otherwise, since models write figures to fit;
# - amounts_in_source: every amount appears in the text the model read (the text layer or an OCR
#   transcription); nil when it read images or the PDF;
# - dates_anchored: the share of rows whose date is the last date printed within DATE_WINDOW
#   characters before that row's amount. Right extractions scored 0.62-0.77, wrong dates under
#   0.2. A heuristic tuned on two statements, not a rule; nil without text.
# Rows with a zero amount ("Balance brought forward") are ignored. A period check was dropped:
# models write the period to fit their dates.
class Ai::Generations::ExtractBankStatement < Ai::Generation
  include Ai::PdfReading::Pages

  prompt "extract_bank_statement"
  schema_name "bank_statement"

  DATE_WINDOW = 120
  MIN_DATES_ANCHORED = 0.5

  NULLABLE_STRING = { type: %w[string null] }.freeze
  NULLABLE_NUMBER = { type: %w[number null] }.freeze

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

  Checks = Data.define(:reconciles, :amounts_in_source, :dates_anchored) do
    # From the hash PdfImport#extraction_checks stores.
    def self.from_h(hash) = new(**members.index_with { hash.to_h.symbolize_keys[_1] })

    # The names of the checks that failed. nil (nothing to check against) never fails.
    def failed
      results = { reconciles: reconciles.present?, amounts_in_source: amounts_in_source != false,
                  dates_anchored: dates_anchored.nil? || dates_anchored >= MIN_DATES_ANCHORED }
      results.reject { |_, passed| passed }.keys
    end

    def passed? = failed.empty?

    # How many checks passed, to pick the best of several failing extractions.
    def score = members.size - failed.size

    def to_h = super.merge(passed: passed?)
  end

  # Batches in document order: rows concatenated, a row repeated at the boundary of two batches
  # dropped (#846: a chunk boundary can cut a table), the first batch's opening figures and the
  # last batch's closing ones.
  def merge_values(values)
    rows = values.each_with_index.flat_map { |value, i| Array(value[:transactions]).map { _1.merge(batch: i) } }
    seen = Hash.new { |hash, key| hash[key] = [] }
    kept = rows.reject do |row|
      key = row.values_at(:date, :amount, :description)
      duplicate = seen[key].any? { (_1 - row[:batch]).abs == 1 }
      seen[key] << row[:batch]
      duplicate
    end

    first = ->(key) { values.lazy.map { _1[key] }.find(&:present?) }
    last = ->(key) { values.reverse.lazy.map { _1[key] }.find(&:present?) }
    periods = values.filter_map { _1[:statement_period] }
    {
      bank_name: first.(:bank_name), account_holder: first.(:account_holder), account_number: first.(:account_number),
      currency: first.(:currency), opening_balance: first.(:opening_balance), closing_balance: last.(:closing_balance),
      statement_period: { start_date: periods.lazy.map { _1[:start_date] }.find(&:present?),
                          end_date: periods.reverse.lazy.map { _1[:end_date] }.find(&:present?) },
      transactions: kept.map { _1.except(:batch) }
    }
  end

  # source: the text the model read, or nil for images and the PDF. balances: the opening and
  # closing balances read from the text layer (AccountStatement::TextMetadataParser), when found.
  def self.checks(value, source: nil, balances: {})
    rows = Array(value[:transactions]).reject { _1[:amount].to_f.zero? }
    opening = balances[:opening_balance] || value[:opening_balance]
    closing = balances[:closing_balance] || value[:closing_balance]
    reconciles = !opening.nil? && !closing.nil? && rows.any? &&
                 (opening.to_d + rows.sum { _1[:amount].to_d }).round(2) == closing.to_d.round(2)
    text = source&.gsub(/\s+/, "")&.downcase
    return Checks.new(reconciles:, amounts_in_source: nil, dates_anchored: nil) if text.blank? || rows.empty?

    Checks.new(reconciles:, amounts_in_source: rows.all? { |row| printed_amounts(row[:amount]).any? { text.include?(_1) } },
               dates_anchored: (rows.count { date_anchored?(_1, rows, text) } / rows.size.to_f).round(2))
  end

  # The value as today's PdfImport#extracted_data holds it.
  def self.statement(value)
    {
      transactions: Array(value[:transactions]).map do |row|
        { date: normal_date(row[:date]), amount: row[:amount]&.to_f, name: row[:description], category: row[:category], notes: row[:reference] }
      end,
      period: { start_date: normal_date(value.dig(:statement_period, :start_date)), end_date: normal_date(value.dig(:statement_period, :end_date)) },
      account_holder: value[:account_holder], account_number: value[:account_number], bank_name: value[:bank_name],
      currency: value[:currency], opening_balance: value[:opening_balance], closing_balance: value[:closing_balance]
    }
  end

  class << self
    private
      def normal_date(text)
        Date.parse(text.to_s).iso8601 if text.present?
      rescue Date::Error
        nil
      end

      # Some occurrence of the row's amount has, as the last date printed (of any row's) in the
      # DATE_WINDOW characters before it, the row's own date.
      def date_anchored?(row, rows, text)
        forms = rows.flat_map { |other| printed_dates(other[:date]).map { [ _1, other[:date] ] } }.uniq
        printed_amounts(row[:amount]).any? do |amount|
          positions(text, amount).any? do |at|
            before = text[[ at - DATE_WINDOW, 0 ].max...at]
            forms.filter_map { |form, date| (index = before.rindex(form)) && [ index, date ] }.max_by(&:first)&.last == row[:date]
          end
        end
      end

      def positions(text, needle)
        found = []
        at = -1
        found << at while (at = text.index(needle, at + 1))
        found
      end

      # 2575.0 as "2575.00" or "2,575.00"; 0.26 also as ".26".
      def printed_amounts(amount)
        plain = format("%.2f", amount.to_f.abs)
        [ plain, plain.gsub(/(\d)(?=(\d{3})+\.)/, '\1,'), plain.sub(/\A0\./, ".") ].uniq
      end

      # 2019-02-01 as "02/01", "2/1", "01/02", "1february", "1feb", "february1"...
      def printed_dates(date)
        day = Date.iso8601(date.to_s)
        %w[%m/%d %-m/%-d %d/%m %-d/%-m %-d%B %-d%b %B%-d %b%-d %Y-%m-%d].map { day.strftime(_1).downcase }.uniq
      rescue Date::Error
        []
      end
  end
end
