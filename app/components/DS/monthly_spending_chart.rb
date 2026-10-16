class DS::MonthlySpendingChart < DesignSystemComponent
  attr_reader :data

  def initialize(data:)
    @data = data
  end

  def max_total
    @max_total ||= begin
      maximum = data[:months].map { |month| month[:total].to_d }.max || 0.to_d
      maximum.positive? ? maximum : 1.to_d
    end
  end

  def categories
    @categories ||= data[:categories].index_by { |category| category[:id] }
  end

  def percentage(amount)
    (amount.to_d / max_total * 100).to_f
  end

  def money(amount)
    helpers.format_money(Money.new(amount.to_d, data[:currency]))
  end

  def month_label(month)
    I18n.l(Date.iso8601(month[:month]), format: :short_month_year)
  end

  def accessible_label(month)
    [ month_label(month),
      (t("pages.dashboard.monthly_spending.partial") if month[:partial]),
      (t("pages.dashboard.monthly_spending.provisional") if month[:missing_exchange_rates].positive?) ].compact.join(", ")
  end
end
