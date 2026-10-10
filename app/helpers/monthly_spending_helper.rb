module MonthlySpendingHelper
  def monthly_spending_selected_ids(key, default)
    value = params[key]
    value.is_a?(Array) && value.all? { |id| id.is_a?(String) } ? value.reject(&:blank?) : default
  end

  def monthly_spending_period_options
    month = Date.current.beginning_of_month
    [
      [ t("pages.dashboard.monthly_spending.last_twelve"), (month - 11.months).strftime("%Y-%m"), month.strftime("%Y-%m") ],
      [ t("pages.dashboard.monthly_spending.this_year"), month.beginning_of_year.strftime("%Y-%m"), month.strftime("%Y-%m") ],
      *(1..3).map { |offset| [ (month.year - offset).to_s, "#{month.year - offset}-01", "#{month.year - offset}-12" ] }
    ]
  end
end
