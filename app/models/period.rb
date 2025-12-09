class Period
  include ActiveModel::Validations, Comparable

  class InvalidKeyError < StandardError; end

  attr_reader :key, :start_date, :end_date

  validates :start_date, :end_date, presence: true, if: -> { PERIODS[key].nil? }
  validates :key, presence: true, if: -> { start_date.nil? || end_date.nil? }
  validate :must_be_valid_date_range

  PERIODS = {
    "last_day" => {
      date_range: -> { [ 1.day.ago.to_date, Date.current ] }
    },
    "current_week" => {
      date_range: -> { [ Date.current.beginning_of_week, Date.current ] }
    },
    "last_7_days" => {
      date_range: -> { [ 7.days.ago.to_date, Date.current ] }
    },
    "current_month" => {
      date_range: -> { [ Date.current.beginning_of_month, Date.current ] }
    },
    "last_month" => {
      date_range: -> { [ 1.month.ago.beginning_of_month.to_date, 1.month.ago.end_of_month.to_date ] }
    },
    "last_30_days" => {
      date_range: -> { [ 30.days.ago.to_date, Date.current ] }
    },
    "last_90_days" => {
      date_range: -> { [ 90.days.ago.to_date, Date.current ] }
    },
    "current_year" => {
      date_range: -> { [ Date.current.beginning_of_year, Date.current ] }
    },
    "last_365_days" => {
      date_range: -> { [ 365.days.ago.to_date, Date.current ] }
    },
    "last_5_years" => {
      date_range: -> { [ 5.years.ago.to_date, Date.current ] }
    },
    "last_10_years" => {
      date_range: -> { [ 10.years.ago.to_date, Date.current ] }
    },
    "all_time" => {
      date_range: -> {
        oldest_date = Current.family&.oldest_entry_date
        start_date = if oldest_date && oldest_date < Date.current
          oldest_date
        else
          5.years.ago.to_date
        end
        [ start_date, Date.current ]
      }
    }
  }
  class << self
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
    if days > 366
      "1 week"
    else
      "1 day"
    end
  end

  def i18n_scope
    "periods.#{key}"
  end

  def label
    I18n.t("#{i18n_scope}.label", default: "Custom Period")
  end

  def label_short
    I18n.t("#{i18n_scope}.label_short", default: "Custom")
  end

  def comparison_label
    I18n.t(
      "#{i18n_scope}.comparison_label",
      default: "#{start_date.strftime(@date_format)} to #{end_date.strftime(@date_format)}"
    )
  end

  private
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
