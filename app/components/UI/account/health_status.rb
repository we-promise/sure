# The account's data-quality problems (Account::HealthStatus), shown under its
# header, where the page shows the sync state.
class UI::Account::HealthStatus < ApplicationComponent
  def initialize(account:)
    @account = account
  end

  def issues
    @issues ||= Account::HealthStatus.new(@account, viewer: Current.user).issues
  end

  def render?
    issues.any?
  end

  # Only the negative-positions issue lists details: one Account::NegativePosition each.
  def detail_text(position)
    t(
      "accounts.health_status.negative_positions.detail",
      name: position.security.name.presence || position.security.ticker,
      ticker: position.security.ticker,
      date: helpers.format_date(position.first_date),
      qty: helpers.format_quantity(position.lowest_qty, exact: true)
    )
  end
end
