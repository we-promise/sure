module MonthlySpendingHelper
  def monthly_spending_share(amount, total)
    return "—" unless total.to_d.positive?
    number_to_percentage(amount.to_d / total.to_d * 100, precision: 1, strip_insignificant_zeros: true)
  end

  def monthly_spending_selected_ids(key, default)
    value = params[key]
    value.is_a?(Array) && value.all? { |id| id.is_a?(String) } ? value.reject(&:blank?) : default
  end

  def monthly_spending_period_options
    year = Date.current.year
    [
      [ t("pages.dashboard.monthly_spending.last_twelve"), "last_twelve" ],
      [ t("pages.dashboard.monthly_spending.this_year"), "this_year" ],
      *(1..3).map { |offset| [ (year - offset).to_s, "year:#{year - offset}" ] }
    ]
  end
end
