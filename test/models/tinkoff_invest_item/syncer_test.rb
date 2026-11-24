require "test_helper"

class TinkoffInvestItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = @family.tinkoff_invest_items.create!(name: "T-Invest", api_key: "test-token")
    @sync = @item.syncs.create!
  end

  test "marks item requires_update when credentials are missing" do
    @item.update_columns(api_key: nil)

    assert_raises(Provider::TinkoffInvest::PortfolioClient::ConfigurationError) do
      TinkoffInvestItem::Syncer.new(@item).perform_sync(@sync)
    end

    assert @item.reload.requires_update?
    assert_equal "auth_error", @sync.reload.sync_stats.dig("errors", 0, "category")
  end

  test "flags pending_account_setup when unlinked accounts remain" do
    @item.stubs(:import_latest_data).returns(true)
    @item.tinkoff_invest_accounts.create!(name: "Brokerage", tinkoff_invest_account_id: "acct-1", currency: "RUB")

    TinkoffInvestItem::Syncer.new(@item).perform_sync(@sync)

    assert @item.reload.pending_account_setup?
  end

  test "processes linked accounts and records sync stats" do
    tinkoff_acct = @item.tinkoff_invest_accounts.create!(
      name: "Brokerage",
      tinkoff_invest_account_id: "acct-1",
      currency: "RUB",
      current_balance: 1000,
      cash_balance: 200,
      raw_portfolio_payload: { "positions" => [ { "instrumentType" => "share" }, { "instrumentType" => "currency" } ] }
    )
    account = @family.accounts.create!(name: "Brokerage", balance: 0, currency: "RUB", accountable: Investment.new)
    tinkoff_acct.ensure_account_provider!(account)

    @item.stubs(:import_latest_data).returns(true)
    @item.expects(:process_accounts).once
    @item.expects(:schedule_account_syncs).once

    TinkoffInvestItem::Syncer.new(@item).perform_sync(@sync)

    assert_not @item.reload.pending_account_setup?
    assert_equal 1, @sync.reload.sync_stats["holdings_processed"]
  end

  test "records auth_error health stats and requires_update on AuthenticationError" do
    @item.stubs(:import_latest_data).raises(Provider::TinkoffInvest::PortfolioClient::AuthenticationError.new("unauthorized"))

    assert_raises(Provider::TinkoffInvest::PortfolioClient::AuthenticationError) do
      TinkoffInvestItem::Syncer.new(@item).perform_sync(@sync)
    end

    assert @item.reload.requires_update?
    assert_equal "auth_error", @sync.reload.sync_stats.dig("errors", 0, "category")
  end
end
