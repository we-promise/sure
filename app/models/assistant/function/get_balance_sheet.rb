class Assistant::Function::GetBalanceSheet < Assistant::Function
  include ActiveSupport::NumberHelper

  MAX_SERIES_POINTS = 400
  INTERVALS = [ "1 day", "1 week", "1 month" ].freeze

  class << self
    def name
      "get_balance_sheet"
    end

    def description
      <<~INSTRUCTIONS
        Use this to get the user's balance sheet with varying amounts of historical data.

        This is great for answering questions like:
        - What is the user's net worth?  What is it composed of?
        - How has the user's wealth changed over time?

        For "net worth over time" questions, pass a named period (or a custom
        start_date and end_date) and an interval to control the granularity of
        the history series. The default is the last 5 years at 1 month.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [],
      properties: {
        period: {
          type: "string",
          enum: Period::PERIODS.keys,
          description: "Named period for the history series (defaults to the last 5 years)"
        },
        start_date: {
          type: "string",
          description: "Custom range start in YYYY-MM-DD format; overrides period when end_date is also given"
        },
        end_date: {
          type: "string",
          description: "Custom range end in YYYY-MM-DD format; overrides period when start_date is also given"
        },
        interval: {
          type: "string",
          enum: INTERVALS,
          description: "Series granularity (defaults to 1 month)"
        }
      }
    )
  end

  def call(params = {})
    period = resolve_period(params)
    return period if period.is_a?(Hash)

    interval = params["interval"].presence_in(INTERVALS) || "1 month"

    if series_points(period, interval) > MAX_SERIES_POINTS
      return error("too_many_points", "That period and interval combination produces too many data points. Use a coarser interval or a shorter period.")
    end

    {
      as_of_date: Date.current,
      oldest_account_start_date: family.oldest_entry_date,
      currency: family.currency,
      net_worth: {
        current: balance_sheet.net_worth_money.format,
        monthly_history: historical_data(period, interval)
      },
      assets: {
        current: balance_sheet.assets.total_money.format,
        monthly_history: historical_data(period, interval, classification: "asset")
      },
      liabilities: {
        current: balance_sheet.liabilities.total_money.format,
        monthly_history: historical_data(period, interval, classification: "liability")
      },
      insights: insights_data
    }
  end

  private
    def balance_sheet
      @balance_sheet ||= family.balance_sheet(user: user)
    end

    def resolve_period(params)
      if params["start_date"].present? && params["end_date"].present?
        Period.custom(
          start_date: Date.parse(params["start_date"]),
          end_date: Date.parse(params["end_date"])
        )
      elsif Period.valid_key?(params["period"].to_s)
        Period.from_key(params["period"])
      else
        observation_start_date = [ 5.years.ago.to_date, family.oldest_entry_date ].max
        Period.custom(start_date: observation_start_date, end_date: Date.current)
      end
    rescue Date::Error
      error("invalid_date", "Dates must be valid and in YYYY-MM-DD format.")
    rescue ActiveModel::ValidationError
      # Period validates the range itself (e.g. start after end)
      error("invalid_date", "start_date must be on or before end_date.")
    end

    def series_points(period, interval)
      days_per_point = { "1 day" => 1, "1 week" => 7, "1 month" => 30 }.fetch(interval)
      period.days / days_per_point
    end

    def historical_data(period, interval, classification: nil)
      scope = user.accessible_accounts.visible
      scope = scope.where(classification: classification) if classification.present?

      if period.start_date == Date.current
        []
      else
        account_ids = scope.pluck(:id)

        builder = Balance::ChartSeriesBuilder.new(
          account_ids: account_ids,
          currency: family.currency,
          period: period,
          favorable_direction: "up",
          interval: interval
        )

        to_ai_time_series(builder.balance_series)
      end
    end

    def insights_data
      assets = balance_sheet.assets.total
      liabilities = balance_sheet.liabilities.total
      ratio = liabilities.zero? ? 0 : (liabilities / assets.to_f)

      {
        debt_to_asset_ratio: number_to_percentage(ratio * 100, precision: 0)
      }
    end

    def error(key, message)
      { error: key, message: message }
    end
end
