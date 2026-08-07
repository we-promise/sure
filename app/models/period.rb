class Period
  include ActiveModel::Validations, Comparable

  class InvalidKeyError < StandardError; end

  attr_reader :key, :start_date, :end_date

  validates :start_date, :end_date, presence: true, if: -> { PERIODS[key].nil? }
  validates :key, presence: true, if: -> { start_date.nil? || end_date.nil? }
  validate :must_be_valid_date_range

  PERIODS = {
    "last_day" => {
      date_range: -> { [ 1.day.ago.to_date, Date.current ] },
      label_short: "1D",
      label: "Last Day",
      comparison_label: "vs. yesterday"
    },
    "current_week" => {
      date_range: -> { [ Date.current.beginning_of_week, Date.current ] },
      label_short: "WTD",
      label: "Current Week",
      comparison_label: "vs. start of week"
    },
    "last_7_days" => {
      date_range: -> { [ 7.days.ago.to_date, Date.current ] },
      label_short: "7D",
      label: "Last 7 Days",
      comparison_label: "vs. last week"
    },
    "current_month" => {
      date_range: -> { [ Date.current.beginning_of_month, Date.current ] },
      label_short: "MTD",
      label: "Current Month",
      comparison_label: "vs. start of month"
    },
    "last_month" => {
      date_range: -> { [ 1.month.ago.beginning_of_month.to_date, 1.month.ago.end_of_month.to_date ] },
      label_short: "LM",
      label: "Last Month",
      comparison_label: "vs. last month"
    },
    "last_30_days" => {
      date_range: -> { [ 30.days.ago.to_date, Date.current ] },
      label_short: "30D",
      label: "Last 30 Days",
      comparison_label: "vs. last 30 days"
    },
    "last_90_days" => {
      date_range: -> { [ 90.days.ago.to_date, Date.current ] },
      label_short: "90D",
      label: "Last 90 Days",
      comparison_label: "vs. last quarter"
    },
    "current_year" => {
      date_range: -> { [ Date.current.beginning_of_year, Date.current ] },
      label_short: "YTD",
      label: "Current Year",
      comparison_label: "vs. start of year"
    },
    "last_365_days" => {
      date_range: -> { [ 365.days.ago.to_date, Date.current ] },
      label_short: "365D",
      label: "Last 365 Days",
      comparison_label: "vs. 1 year ago"
    },
    "last_5_years" => {
      date_range: -> { [ 5.years.ago.to_date, Date.current ] },
      label_short: "5Y",
      label: "Last 5 Years",
      comparison_label: "vs. 5 years ago"
    },
    "last_10_years" => {
      date_range: -> { [ 10.years.ago.to_date, Date.current ] },
      label_short: "10Y",
      label: "Last 10 Years",
      comparison_label: "vs. 10 years ago"
    },
    "all_time" => {
      date_range: -> {
        oldest_date = Current.family&.oldest_entry_date
        # If no family or no entries exist, use a reasonable historical fallback
        # to ensure "All Time" represents a meaningful range, not just today
        start_date = if oldest_date && oldest_date < Date.current
          oldest_date
        else
          5.years.ago.to_date
        end
        [ start_date, Date.current ]
      },
      label_short: "All",
      label: "All Time",
      comparison_label: "vs. beginning"
    }
  }

  class << self
    def valid_key?(key)
      PERIODS.key?(key)
    end

    def from_key(key)
      unless PERIODS.key?(key)
        raise InvalidKeyError, "Invalid period key: #{key}"
      end

      start_date, end_date = PERIODS[key].fetch(:date_range).call

      new(key: key, start_date: start_date, end_date: end_date)
    end

    def custom(start_date:, end_date:)
      new(start_date: start_date, end_date: end_date)
    end

    def all
      PERIODS.map { |key, period| from_key(key) }
    end

    def as_options
      all.map { |period| [ period.label_short, period.key ] }
    end

    def current_month_for(family)
      return from_key("current_month") unless family&.uses_custom_month_start?

      # Keep the semantic key so callers (e.g. the period picker) can identify
      # this as "current month" even though the date range is custom.
      custom_period = family.current_custom_month_period
      new(key: "current_month", start_date: custom_period.start_date, end_date: custom_period.end_date)
    end

    def last_month_for(family)
      return from_key("last_month") unless family&.uses_custom_month_start?

      current_start = family.custom_month_start_for(Date.current)
      last_month_date = current_start - 1.day
      start_date = family.custom_month_start_for(last_month_date)
      end_date = family.custom_month_end_for(last_month_date)
      new(key: "last_month", start_date: start_date, end_date: end_date)
    end
  end

  PERIODS.each do |key, period|
    define_singleton_method(key) do
      from_key(key)
    end
  end

  def initialize(start_date: nil, end_date: nil, key: nil, date_format: "%b %d, %Y")
    @key = key
    @start_date = start_date
    @end_date = end_date
    @date_format = date_format
    validate!
  end

  def <=>(other)
    [ start_date, end_date ] <=> [ other.start_date, other.end_date ]
  end

  def date_range
    start_date..end_date
  end

  def days
    (end_date - start_date).to_i + 1
  end

  def within?(other)
    start_date >= other.start_date && end_date <= other.end_date
  end

  def interval
    if end_date > start_date.advance(years: 5)   # more than 5 calendar years → monthly
      "1 month"
    elsif end_date > start_date.advance(years: 1) # more than 1 calendar year → weekly
      "1 week"
    else
      "1 day"
    end
  end

  def label
    if key
      I18n.t("period.#{key}.label", default: key_metadata&.fetch(:label) || "Custom Period")
    else
      I18n.t("period.custom.label", default: "Custom Period")
    end
  end

  def label_short
    if key
      I18n.t("period.#{key}.label_short", default: key_metadata&.fetch(:label_short) || "Custom")
    else
      I18n.t("period.custom.label_short", default: "Custom")
    end
  end

  def comparison_label
    if key
      I18n.t("period.#{key}.comparison_label", default: key_metadata&.fetch(:comparison_label) || ->(*) { localized_comparison_range })
    else
      localized_comparison_range
    end
  end

  private
    def localized_comparison_range
      I18n.t(
        "period.custom.comparison_label",
        start: I18n.l(start_date, format: :long).strip,
        end: I18n.l(end_date, format: :long).strip
      )
    end

    def key_metadata
      @key_metadata ||= PERIODS[key]
    end

    def must_be_valid_date_range
      return if start_date.nil? || end_date.nil?
      unless start_date.is_a?(Date) && end_date.is_a?(Date)
        errors.add(:start_date, "must be a valid date, got #{start_date.inspect}")
        errors.add(:end_date, "must be a valid date, got #{end_date.inspect}")
        return
      end

      errors.add(:start_date, "must be before end date") if start_date > end_date
    end
end
