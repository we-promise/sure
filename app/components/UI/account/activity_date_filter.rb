class UI::Account::ActivityDateFilter < ApplicationComponent
  attr_reader :account, :selected_year, :selected_month

  def initialize(account:, selected_year: nil, selected_month: nil)
    @account = account
    @selected_year = selected_year
    @selected_month = selected_month
  end

  def years
    @years ||= begin
      oldest = account.entries.minimum(:date)&.year || Date.current.year
      newest = Date.current.year
      (oldest..newest).to_a.reverse
    end
  end

  def months
    @months ||= (1..12).map { |m| [ m, I18n.t("date.month_names")[m] ] }
  end

  def trigger_label
    if selected_year && selected_month
      I18n.t("date.month_names")[selected_month] + " #{selected_year}"
    elsif selected_year
      selected_year.to_s
    else
      I18n.t("accounts.show.activity.filter_period.all_time")
    end
  end

  def active?
    selected_year.present?
  end

  def href_for(year: nil, month: nil)
    base_params = helpers.request.query_parameters.except("activity_year", "activity_month", "page").to_h

    if year
      base_params[:activity_year] = year
      base_params[:activity_month] = month if month
    end

    "#{helpers.account_path(account)}?#{base_params.to_query}"
  end

  def clear_href
    base_params = helpers.request.query_parameters.except("activity_year", "activity_month", "page").to_h
    query = base_params.to_query
    query.empty? ? helpers.account_path(account) : "#{helpers.account_path(account)}?#{query}"
  end

  def year_selected?(year)
    selected_year == year
  end

  def month_selected?(month)
    selected_year.present? && selected_month == month
  end
end
