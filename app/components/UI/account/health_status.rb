# The account's data-quality problems (Account::HealthStatus), shown under its
# header, where the page shows the sync state.
class UI::Account::HealthStatus < ApplicationComponent
  def initialize(account:)
    @account = account
  end

  def issues
    @issues ||= Account::HealthStatus.new(@account).issues
  end

  def render?
    issues.any?
  end

  # Details are an Account::NegativePosition per position, or the open
  # Balance::IntegrityChecker::Gap.
  def detail_text(detail)
    case detail
    when Balance::IntegrityChecker::Gap then balance_gap_text(detail)
    else negative_position_text(detail)
    end
  end

  private
    def balance_gap_text(gap)
      t(
        gap.difference.positive? ? "accounts.health_status.balance_gap.detail_higher" : "accounts.health_status.balance_gap.detail_lower",
        difference: Money.new(gap.difference.abs, @account.currency).format,
        since: helpers.format_date(gap.first_open_waypoint.date)
      )
    end

    def negative_position_text(position)
      t(
        "accounts.health_status.negative_positions.detail",
        name: position.security.name.presence || position.security.ticker,
        ticker: position.security.ticker,
        date: helpers.format_date(position.first_date),
        qty: helpers.format_quantity(position.lowest_qty, exact: true)
      )
    end
end
