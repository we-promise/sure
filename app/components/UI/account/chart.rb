class UI::Account::Chart < ApplicationComponent
  attr_reader :account

  def initialize(account:, period: nil, view: nil)
    @account = account
    @period = period
    @view = view
  end

  def period
    @period ||= Period.last_30_days
  end

  def holdings_value_money
    account.balance_money - account.cash_balance_money
  end

  def view_balance_money
    case view
    when "balance"
      account.balance_money
    when "holdings_balance"
      holdings_value_money
    when "cash_balance"
      account.cash_balance_money
    end
  end

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

  def converted_balance_money
    return nil unless foreign_currency?

    begin
      account.balance_money.exchange_to(account.family.currency)
    rescue Money::ConversionError
      nil
    end
  end

  def view
    @view ||= "balance"
  end

  def series
    account.balance_series(period: period, view: view)
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
end
