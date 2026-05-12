# frozen_string_literal: true

require "csv"
require "stringio"

class AccountStatement::MetadataDetector
  DATE_PATTERNS = [
    /(?<![a-z0-9])\d{4}[-_\.]\d{1,2}[-_\.]\d{1,2}(?![a-z0-9])/,
    /(?<![a-z0-9])\d{1,2}[-_\.]\d{1,2}[-_\.]\d{4}(?![a-z0-9])/,
    /(?<![a-z0-9])\d{8}(?![a-z0-9])/
  ].freeze

  MONTH_PATTERN = /
    (?<![a-z0-9])
    (?:
      (?<year_first>\d{4})[-_\.](?<month_first>0?[1-9]|1[0-2])
      |
      (?<month_name>jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)
      [-_\s\.]+(?<year_second>\d{4})
    )
    (?![a-z0-9])
  /ix.freeze

  LAST4_PATTERN = /(?:^|[^a-z0-9])(?:x{2,}|ending|last\s*4|acct|account|card)[^\d]*(\d{4})(?=\D|$)/i.freeze
  GENERIC_FILENAME_HINTS = [
    "statement",
    "statements",
    "bank statement",
    "bank statements",
    "account statement",
    "account statements",
    "credit card statement",
    "card statement"
  ].freeze
  MAX_CSV_COLUMNS = 100
  MAX_CSV_DATE_SAMPLES = 250
  MAX_CSV_SAMPLE_BYTES = 256

  attr_reader :statement, :content

  def initialize(statement, content:)
    @statement = statement
    @content = content
  end

  def apply
    output = statement.sanitized_parser_output || {}
    metadata_sources = []

    if detect_from_filename
      metadata_sources << "filename"
    end

    if statement.csv? && detect_from_csv(output)
      metadata_sources << "csv_dates"
    elsif statement.xlsx?
      output["spreadsheet_detection"] = "filename_only"
    elsif statement.pdf?
      output["pdf_detection"] = "filename_only"
    end

    output["metadata_sources"] = metadata_sources
    statement.sanitized_parser_output = output
    statement.parser_confidence ||= if metadata_sources.include?("csv_dates")
      0.65
    elsif metadata_sources.any?
      0.45
    else
      0.1
    end
  end

  private

    def detect_from_filename
      basename = File.basename(statement.filename.to_s, ".*")
      return false if basename.blank?

      detected = false

      if (last4 = basename.match(LAST4_PATTERN)&.captures&.first)
        statement.account_last4_hint ||= last4
        detected = true
      end

      dates = DATE_PATTERNS.flat_map { |pattern| basename.scan(pattern) }
                           .map { |match| Array(match).first }
                           .filter_map { |value| parse_date(value) }
                           .uniq
                           .sort

      if dates.size >= 2
        statement.period_start_on ||= dates.first
        statement.period_end_on ||= dates.last
        detected = true
      elsif dates.size == 1
        statement.period_start_on ||= dates.first.beginning_of_month
        statement.period_end_on ||= dates.first.end_of_month
        detected = true
      elsif (month_date = parse_month_from_filename(basename))
        statement.period_start_on ||= month_date.beginning_of_month
        statement.period_end_on ||= month_date.end_of_month
        detected = true
      end

      hint = basename
        .gsub(LAST4_PATTERN, "")
        .gsub(/\b\d{4}[-_\.]\d{1,2}(?:[-_\.]\d{1,2})?\b/, "")
        .gsub(/\b\d{8}\b/, "")
        .tr("_-", " ")
        .gsub(/\b(?:19|20)\d{2}\b/, "")
        .gsub(/\b(?:0?[1-9]|1[0-2])\b/, "")
        .squish
        .presence

      if (meaningful_hint = meaningful_filename_hint(hint))
        statement.institution_name_hint ||= meaningful_hint
        statement.account_name_hint ||= meaningful_hint
        detected = true
      end

      detected
    end

    def detect_from_csv(output)
      csv = CSV.new(StringIO.new(content.to_s), headers: true, liberal_parsing: true)
      first_row = csv.shift
      return false if first_row.blank?

      headers = first_row.headers.compact.map(&:to_s)
      return false if headers.size > MAX_CSV_COLUMNS

      date_header = headers.find { |header| csv_sample_text(header).to_s.match?(/date|posted|transaction/i) }
      return false if date_header.blank?

      samples = [ csv_sample_text(first_row[date_header]) ].compact_blank
      csv.each do |row|
        break if samples.size >= MAX_CSV_DATE_SAMPLES

        sample = csv_sample_text(row[date_header])
        samples << sample if sample.present?
      end
      return false if samples.blank?

      date_format = Import.detect_date_format(samples)
      dates = samples.filter_map { |sample| parse_date_with_format(sample, date_format) }.uniq.sort
      return false if dates.blank?

      statement.period_start_on ||= dates.first
      statement.period_end_on ||= dates.last
      output["csv"] = {
        "date_header" => date_header.to_s,
        "date_format" => date_format,
        "rows_sampled" => samples.size
      }
      true
    rescue CSV::MalformedCSVError
      false
    end

    def csv_sample_text(value)
      text = value.to_s
      return nil if text.bytesize > MAX_CSV_SAMPLE_BYTES

      text
    end

    def meaningful_filename_hint(hint)
      return nil if hint.blank?

      normalized = hint.downcase.gsub(/[^a-z0-9]+/, " ").squish
      without_generic_words = normalized
        .gsub(/\b(?:bank|account|card|credit|debit|statement|statements)\b/, "")
        .squish

      return nil if GENERIC_FILENAME_HINTS.include?(normalized) || without_generic_words.blank?

      hint
    end

    def parse_date(value)
      text = value.to_s.tr("_", "-")
      date = if text.match?(/\A\d{8}\z/)
        Date.strptime(text, "%Y%m%d")
      else
        Date.parse(text)
      end

      AccountStatement::MetadataDetector.reasonable_date?(date) ? date : nil
    rescue Date::Error, ArgumentError
      nil
    end

    def parse_date_with_format(value, format)
      date = Date.strptime(value.to_s, format)
      AccountStatement::MetadataDetector.reasonable_date?(date) ? date : nil
    rescue Date::Error, ArgumentError
      nil
    end

    def parse_month_from_filename(basename)
      match = basename.match(MONTH_PATTERN)
      return nil unless match

      year = (match[:year_first] || match[:year_second]).to_i
      month = if match[:month_first]
        match[:month_first].to_i
      else
        Date::ABBR_MONTHNAMES.index(match[:month_name][0, 3].capitalize)
      end

      date = Date.new(year, month, 1)
      AccountStatement::MetadataDetector.reasonable_date?(date) ? date : nil
    rescue Date::Error, NoMethodError
      nil
    end

    def self.reasonable_date?(date)
      Import.reasonable_date_range.cover?(date)
    end
end
