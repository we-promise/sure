class UI::Account::Chart < ApplicationComponent
  attr_reader :account, :loan_chart

  # `loan_chart` is a Loan::PayoffChart payload, built by the controller for a
  # loan account with a schedule and nil for everything else. When present the
  # inner chart element becomes the loan balance chart -- recorded balance,
  # original schedule and projection on one axis -- and the rest of this card
  # (title, hero figure, trend, period picker, Turbo frame) is unchanged. Every
  # other account type takes the branch it always took (#100, decision 7).
  # The page's reference date travels inside the payload (`today`), so the
  # component takes no date of its own.
  def initialize(account:, period: nil, view: nil, loan_chart: nil)
    @account = account
    @period = period
    @view = view
    @loan_chart = loan_chart
  end

  def loan_chart?
    loan_chart.present?
  end

  def loan_chart_id
    dom_id(account, :loan_chart)
  end

  def loan_table_id
    dom_id(account, :loan_chart_table)
  end

  # The series with a line inside the domain, in drawing order, each with the
  # style the controller gives it. Style is carried by the legend as well as
  # the line: solid is fact, dashed is forecast, and hue alone would fail in
  # greyscale and under deuteranopia.
  LOAN_SERIES_STYLES = {
    "actual" => { token: "--color-success", dashed: false },
    "scheduled" => { token: "--color-destructive", dashed: true },
    "projected" => { token: "--color-success", dashed: true }
  }.freeze

  def loan_legend
    LOAN_SERIES_STYLES.select { |key, _| loan_chart[:visible].map(&:to_s).include?(key) }
  end

  def loan_projected_payoff_date
    loan_chart[:projected_payoff_date] && Date.iso8601(loan_chart[:projected_payoff_date])
  end

  # The projection ran but the contracted repayment never clears the balance:
  # there is a line to draw and no payoff date to quote.
  def loan_projection_not_converged?
    loan_chart[:projected].any? && loan_projected_payoff_date.nil?
  end

  # Never "behind": the projection walks only the remaining contracted dates,
  # so months_saved is zero or positive. A borrower whose balance the contract
  # no longer clears has no payoff date at all and takes the not-converged
  # notice instead, with the balloon it would leave.
  def loan_schedule_comparison
    months = loan_chart[:months_saved].to_i
    return I18n.t("UI.account.chart.loan.on_schedule") if months.zero?

    I18n.t("UI.account.chart.loan.months_saved", count: months)
  end

  def loan_balloon_money
    Money.new(loan_chart[:balloon].to_f, loan_chart[:currency])
  end

  def loan_interest_saved_money
    Money.new(loan_chart[:interest_saved].to_f.abs, loan_chart[:currency])
  end

  def loan_interest_saved_title
    key = loan_chart[:interest_saved].to_f.negative? ? "interest_added" : "interest_saved"
    I18n.t("UI.account.chart.loan.#{key}")
  end

  def loan_money(amount)
    return nil if amount.nil?

    Money.new(amount, loan_chart[:currency]).format
  end

  def period
    @period ||= Period.last_30_days
  end

  def holdings_value_money
    account.balance_money - account.cash_balance_money
  end

  # Money value shown as the main indicator for the selected chart view.
  def view_balance_money
    case view
    when "balance"
      account.balance_money
    when "holdings_balance"
      holdings_value_money
    when "cash_balance"
      account.cash_balance_money
    when "gains"
      gains_money
    end
  end

  # Formatted main indicator. Gains are signed explicitly (e.g. "+€79.53") since
  # a gain of zero-or-more is otherwise indistinguishable from a balance.
  def view_balance_display
    signed_format(view_balance_money)
  end

  # Formatted family-currency amount for foreign-currency accounts, signed the
  # same way as the main indicator. Nil when no conversion applies.
  def converted_balance_display
    converted_balance_money&.then { |money| signed_format(money) }
  end

  # Label displayed above the main indicator, based on account type and chart view.
  def title
    case account.accountable_type
    when "Investment", "Crypto"
      case view
      when "balance"
        I18n.t("UI.account.chart.title.total_account_value")
      when "holdings_balance"
        I18n.t("UI.account.chart.title.holdings_value")
      when "cash_balance"
        I18n.t("UI.account.chart.title.cash_value")
      when "gains"
        I18n.t("UI.account.chart.title.total_gains")
      end
    when "Property"
      I18n.t("UI.account.chart.title.estimated_property_value")
    when "Vehicle"
      I18n.t("UI.account.chart.title.estimated_vehicle_value")
    when "CreditCard", "OtherLiability"
      I18n.t("UI.account.chart.title.debt_balance")
    when "Loan"
      I18n.t("UI.account.chart.title.remaining_principal_balance")
    else
      I18n.t("UI.account.chart.title.balance")
    end
  end

  def foreign_currency?
    account.currency != account.family.currency
  end

  # Main indicator converted to the family currency for foreign-currency accounts,
  # or nil when no conversion applies (same currency or missing exchange rate).
  def converted_balance_money
    return nil unless foreign_currency?

    begin
      base_money = view == "gains" ? gains_money : account.balance_money
      base_money.exchange_to(account.family.currency)
    rescue Money::ConversionError
      nil
    end
  end

  def view
    @view ||= "balance"
  end

  # Read by the trend, its comparison label and the chart mount; built once.
  def series
    @series ||= account.balance_series(period: period, view: view)
  end

  # Current total unrealized gains, taken from the series so the main indicator
  # always matches the last point of the chart (there is no stored gains column).
  def gains_money
    series.values.last&.value || Money.new(0, account.currency)
  end

  def trend
    series.trend
  end

  def comparison_label
    start_date = series.start_date
    return period.comparison_label if start_date.blank?

    if start_date > period.start_date
      I18n.t("UI.account.chart.vs_available_history")
    else
      period.comparison_label
    end
  end

  private
    # Prefixes positive gains with "+"; other views keep plain Money formatting.
    def signed_format(money)
      return money.format unless view == "gains" && money.amount.positive?

      "+#{money.format}"
    end
end
