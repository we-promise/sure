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
end
