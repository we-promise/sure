class User::MonthlySpendingPreferences
  KEY = "monthly_spending_filters"

  def initialize(user)
    @user = user
  end

  def self.period_dates(period)
    month = Date.current.beginning_of_month
    case period
    when "last_twelve" then [ month - 11.months, month ]
    when "this_year" then [ month.beginning_of_year, month ]
    else
      if period.is_a?(String) && period.match?(/\Ayear:\d{4}\z/)
        year = period.delete_prefix("year:").to_i
        [ Date.new(year, 1, 1), Date.new(year, 12, 1) ] if year.positive?
      end
    end
  end

  def self.month_param(params, key)
    if params.key?("#{key}_year") || params.key?("#{key}_month")
      year, month = params["#{key}_year"], params["#{key}_month"]
      if year.is_a?(String) && month.is_a?(String) && year.match?(/\A\d{1,4}\z/) && month.match?(/\A\d{1,2}\z/)
        return format("%04d-%02d-01", year.to_i, month.to_i)
      end
      return "#{year}-#{month}"
    end
    value = params[key]
    return if value.nil?
    if value.is_a?(String) && (match = value.match(/\A(\d{4})-(\d{1,2})\z/))
      return format("%04d-%02d-01", match[1].to_i, match[2].to_i)
    end
    value
  end


  def self.selection(params, dates: nil)
    { from: month_param(params, :monthly_spending_from) || dates&.first&.iso8601,
      to: month_param(params, :monthly_spending_to) || dates&.last&.iso8601,
      account_ids: params[:monthly_spending_account_ids], category_ids: params[:monthly_spending_category_ids] }
  end

  def query_params
    saved = @user.preferences&.[](KEY)
    return {} unless saved.is_a?(Hash)
    dates = self.class.period_dates(saved["period"])
    result = { "monthly_spending_period" => saved["period"],
      "monthly_spending_from" => dates ? dates.first.strftime("%Y-%m") : saved["from"],
      "monthly_spending_to" => dates ? dates.last.strftime("%Y-%m") : saved["to"] }
    %w[account_ids category_ids].each do |key|
      ids = saved[key]
      result["monthly_spending_#{key}"] = ids.empty? ? [ "" ] : ids if ids.is_a?(Array)
    end
    result.compact
  end

  def save(spending, period:)
    dates = self.class.period_dates(period)
    period = "custom" unless dates == [ spending.from, spending.to ]
    @user.update_dashboard_preferences({ KEY => {
      "period" => period, "from" => spending.from.strftime("%Y-%m"),
      "to" => spending.to.strftime("%Y-%m"), "account_ids" => spending.account_ids,
      "category_ids" => spending.category_ids
    } })
  end

  def reset
    @user.update_dashboard_preferences({ KEY => nil })
  end
end
