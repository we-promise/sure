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

    assert_equal :error, issue.severity
    assert_equal I18n.t("accounts.health_status.sync_failed.message"), issue.message
    assert_nil issue.link
  end

  test "a stale last sync is a warning" do
    @account.syncs.create!(status: :stale, created_at: 2.days.ago)

    issue = Account::HealthStatus.new(@account).issues.sole

    assert_equal I18n.t("accounts.health_status.sync_stale.message"), issue.message
    assert_equal :warning, issue.severity
  end

  # Sync.clean marks it stale only after a day; the header stops showing it as
  # syncing after Sync::VISIBLE_FOR.
  test "a retry whose job was lost after a failure is a stale warning" do
    @account.syncs.create!(status: :failed, failed_at: 2.hours.ago, created_at: 2.hours.ago)
    @account.syncs.create!(status: :pending, created_at: Sync::VISIBLE_FOR.ago - 1.minute)

    issue = Account::HealthStatus.new(@account).issues.sole

    assert_equal I18n.t("accounts.health_status.sync_stale.message"), issue.message
    assert_equal :warning, issue.severity
  end

  test "a sync still running shows no issue" do
    @account.syncs.create!(status: :failed, failed_at: 2.hours.ago, created_at: 2.hours.ago)
    @account.syncs.create!(status: :syncing, created_at: 1.minute.ago)

    assert_empty Account::HealthStatus.new(@account).issues
  end

  test "a sync that went through after a failed one clears the issue" do
    @account.syncs.create!(status: :failed, failed_at: 2.hours.ago, created_at: 2.hours.ago)
    @account.syncs.create!(status: :completed, completed_at: 1.hour.ago, created_at: 1.hour.ago)

    assert_empty Account::HealthStatus.new(@account).issues
  end

  test "a connection whose session ended asks an admin to reconnect under bank sync" do
    item = trade_republic_items(:configured_item)
    item.update!(session_expires_at: 1.minute.ago)
    @account.account_providers.create!(provider: trade_republic_accounts(:main_account))
    # The account's own sync still goes through; only the connection's fails.
    @account.syncs.create!(status: :completed, completed_at: 1.hour.ago)

    issue = Account::HealthStatus.new(@account, viewer: users(:family_admin)).issues.sole

    assert_equal :warning, issue.severity
    assert_equal I18n.t("accounts.health_status.provider_reconnect.message", provider: item.institution_display_name), issue.message
    assert_equal I18n.t("accounts.health_status.provider_reconnect.hint"), issue.hint
    assert_equal I18n.t("accounts.health_status.provider_reconnect.link_bank_sync"), issue.link[:text]
    assert_equal Rails.application.routes.url_helpers.settings_providers_path, issue.link[:href]
  end

  test "a member who can't reconnect is told to ask an admin, without a link" do
    trade_republic_items(:configured_item).update!(session_expires_at: 1.minute.ago)
    @account.account_providers.create!(provider: trade_republic_accounts(:main_account))

    issue = Account::HealthStatus.new(@account, viewer: users(:family_member)).issues.sole

    assert_equal I18n.t("accounts.health_status.provider_reconnect.hint_ask_admin"), issue.hint
    assert_nil issue.link
  end

  test "a connection marked as needing an update asks to reconnect" do
    tr_account = TradeRepublicAccount.create!(
      trade_republic_item: trade_republic_items(:requires_update_item),
      name: "Trade Republic (DE9999)", trade_republic_account_id: "DE9999", currency: "EUR"
    )
    @account.account_providers.create!(provider: tr_account)

    issue = Account::HealthStatus.new(@account, viewer: users(:family_admin)).issues.sole

    assert_equal I18n.t("accounts.health_status.provider_reconnect.message", provider: tr_account.trade_republic_item.institution_display_name), issue.message
  end

  test "a connection with a live session shows no issue" do
    trade_republic_items(:configured_item).update!(session_expires_at: 1.hour.from_now)
    @account.account_providers.create!(provider: trade_republic_accounts(:main_account))

    assert_empty Account::HealthStatus.new(@account, viewer: users(:family_admin)).issues
  end

  test "a Plaid connection still linked through the legacy column links to its card" do
    account = accounts(:connected)
    item = plaid_items(:one)
    item.update!(status: :requires_update)
    assert_empty account.account_providers

    issue = Account::HealthStatus.new(account, viewer: users(:family_admin)).issues.sole

    assert_equal I18n.t("accounts.health_status.provider_reconnect.message", provider: item.name), issue.message
    assert_equal I18n.t("accounts.health_status.provider_reconnect.link_accounts"), issue.link[:text]
    assert_equal Rails.application.routes.url_helpers.accounts_path(anchor: ActionView::RecordIdentifier.dom_id(item)), issue.link[:href]
  end

  test "a member who owns a Plaid connection may reconnect it, other members may not" do
    account = accounts(:connected)
    item = plaid_items(:one)
    item.update!(status: :requires_update, owner: users(:family_member))

    owner_issue = Account::HealthStatus.new(account, viewer: users(:family_member)).issues.sole
    assert_equal I18n.t("accounts.health_status.provider_reconnect.hint"), owner_issue.hint
    assert_equal Rails.application.routes.url_helpers.accounts_path(anchor: ActionView::RecordIdentifier.dom_id(item)), owner_issue.link[:href]

    item.update!(owner: users(:family_admin))
    other_issue = Account::HealthStatus.new(account.reload, viewer: users(:family_member)).issues.sole
    assert_equal I18n.t("accounts.health_status.provider_reconnect.hint_ask_admin"), other_issue.hint
    assert_nil other_issue.link
  end

  test "a SimpleFIN connection still linked through the legacy column links to its card" do
    item = SimplefinItem.create!(family: @account.family, name: "SF Conn", access_url: "https://example.com/access", status: :requires_update)
    simplefin_account = SimplefinAccount.create!(
      simplefin_item: item, name: "Brokerage", account_id: "acct_hs_1",
      currency: "USD", account_type: "investment", current_balance: 10_000
    )
    @account.update!(simplefin_account: simplefin_account)

    issue = Account::HealthStatus.new(@account, viewer: users(:family_admin)).issues.sole

    assert_equal I18n.t("accounts.health_status.provider_reconnect.message", provider: item.name), issue.message
    assert_equal Rails.application.routes.url_helpers.accounts_path(anchor: ActionView::RecordIdentifier.dom_id(item)), issue.link[:href]
  end

  test "positions below zero list each security and link to the holdings tab" do
    @account.entries.create!(
      name: "Sell 3 shares of MSFT", date: 3.days.ago.to_date, amount: -1200, currency: "USD",
      entryable: Trade.new(security: securities(:msft), qty: -3, price: 400, currency: "USD", investment_activity_label: "Sell")
    )
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    issue = Account::HealthStatus.new(@account).issues.sole

    assert_equal :warning, issue.severity
    assert_equal I18n.t("accounts.health_status.negative_positions.message"), issue.message
    assert_equal [ Account::NegativePosition.new(securities(:msft), 3.days.ago.to_date, -3) ], issue.details
    assert_equal I18n.t("accounts.health_status.negative_positions.hint"), issue.hint
    assert_equal Rails.application.routes.url_helpers.account_path(@account, tab: "holdings"), issue.link[:href]
  end
end
