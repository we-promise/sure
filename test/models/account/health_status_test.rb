require "test_helper"

class Account::HealthStatusTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:investment)
  end

  test "a healthy account has no issues" do
    @account.syncs.create!(status: :completed, completed_at: 1.hour.ago)

    assert_empty Account::HealthStatus.new(@account).issues
  end

  test "a failed last sync is an error" do
    @account.syncs.create!(status: :failed, failed_at: 1.hour.ago, error: "Provider timeout")

    issue = Account::HealthStatus.new(@account).issues.sole

    assert_equal :sync_failed, issue.key
    assert_equal :error, issue.severity
    assert_equal I18n.t("accounts.health_status.sync_failed.message"), issue.message
    assert_nil issue.link
  end

  test "a stale last sync is a warning" do
    @account.syncs.create!(status: :stale, created_at: 2.days.ago)

    issue = Account::HealthStatus.new(@account).issues.sole

    assert_equal :sync_stale, issue.key
    assert_equal :warning, issue.severity
  end

  test "a sync that went through after a failed one clears the issue" do
    @account.syncs.create!(status: :failed, failed_at: 2.hours.ago, created_at: 2.hours.ago)
    @account.syncs.create!(status: :completed, completed_at: 1.hour.ago, created_at: 1.hour.ago)

    assert_empty Account::HealthStatus.new(@account).issues
  end

  test "positions below zero list each security and link to the holdings tab" do
    @account.entries.create!(
      name: "Sell 3 shares of MSFT", date: 3.days.ago.to_date, amount: -1200, currency: "USD",
      entryable: Trade.new(security: securities(:msft), qty: -3, price: 400, currency: "USD", investment_activity_label: "Sell")
    )
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    issue = Account::HealthStatus.new(@account).issues.sole

    assert_equal :negative_positions, issue.key
    assert_equal :warning, issue.severity
    assert_equal I18n.t("accounts.health_status.negative_positions.message"), issue.message
    assert_equal 1, issue.details.size
    assert_match "Microsoft (MSFT)", issue.details.first
    assert_match "-3", issue.details.first
    assert_equal I18n.t("accounts.health_status.negative_positions.hint"), issue.hint
    assert_equal Rails.application.routes.url_helpers.account_path(@account, tab: "holdings"), issue.link[:href]
  end
end
