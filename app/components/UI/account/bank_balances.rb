class UI::Account::BankBalances < ApplicationComponent
  attr_reader :presenter

  def initialize(account:)
    @presenter = BankBalancesPresenter.new(account: account)
  end

  def render?
    presenter.render?
  end

  def format_time(value)
    zone = Time.zone || Time.zone_default || ActiveSupport::TimeZone["UTC"]
    t("UI.account.bank_balances.time_with_zone", time: l(value.in_time_zone(zone), format: :long), time_zone: zone.name)
  end
end
