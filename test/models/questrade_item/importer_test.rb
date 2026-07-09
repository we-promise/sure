# frozen_string_literal: true

require "test_helper"
require "ostruct"

class QuestradeItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @questrade_item = @family.questrade_items.create!(name: "Test", refresh_token: "dummy-token")
    @questrade_account = @questrade_item.questrade_accounts.create!(
      questrade_account_id: "11111111",
      name: "TFSA (11111111)",
      currency: "CAD",
      current_balance: 1500
    )
  end

  test "does not prune an account whose import fails" do
    provider = stub_provider(accounts: [
      { "number" => "11111111", "type" => "TFSA", "status" => "Active" }
    ])
    QuestradeAccount.any_instance.stubs(:upsert_from_questrade!).raises(StandardError, "encryption hiccup")

    QuestradeItem::Importer.new(@questrade_item, questrade_provider: provider).import

    assert QuestradeAccount.exists?(@questrade_account.id),
      "an account that still exists upstream must survive a failed import"
  end

  test "prunes accounts that are gone upstream" do
    provider = stub_provider(accounts: [
      { "number" => "22222222", "type" => "Margin", "status" => "Active" }
    ])

    QuestradeItem::Importer.new(@questrade_item, questrade_provider: provider).import

    assert_not QuestradeAccount.exists?(@questrade_account.id)
  end

  test "authentication error during account import marks the item requires_update" do
    provider = stub_provider(accounts: [
      { "number" => "11111111", "type" => "TFSA", "status" => "Active" }
    ])
    QuestradeAccount.any_instance.stubs(:upsert_from_questrade!)
      .raises(Provider::Questrade::AuthenticationError, "token expired")

    assert_raises(Provider::Questrade::AuthenticationError) do
      QuestradeItem::Importer.new(@questrade_item, questrade_provider: provider).import
    end
    assert_equal "requires_update", @questrade_item.reload.status
  end

  test "authentication error while fetching balances marks the item requires_update" do
    link_account!
    provider = stub_provider(accounts: [
      { "number" => "11111111", "type" => "TFSA", "status" => "Active" }
    ])
    provider.stubs(:get_balances).raises(Provider::Questrade::AuthenticationError, "token expired")

    assert_raises(Provider::Questrade::AuthenticationError) do
      QuestradeItem::Importer.new(@questrade_item, questrade_provider: provider).import
    end
    assert_equal "requires_update", @questrade_item.reload.status
  end

  test "non-auth balance failures are tolerated and the sync continues" do
    link_account!
    provider = stub_provider(accounts: [
      { "number" => "11111111", "type" => "TFSA", "status" => "Active" }
    ])
    provider.stubs(:get_balances).raises(StandardError, "flaky endpoint")

    assert_nothing_raised do
      QuestradeItem::Importer.new(@questrade_item, questrade_provider: provider).import
    end
    assert_equal "good", @questrade_item.reload.status
  end

  test "start date honors sync_start_date on the initial fetch only" do
    importer = QuestradeItem::Importer.new(@questrade_item, questrade_provider: stub_provider(accounts: []))
    @questrade_account.update!(sync_start_date: Date.new(2024, 1, 15))

    assert_equal Date.new(2024, 1, 15), importer.send(:calculate_start_date, @questrade_account)

    # After a completed fetch with enough history, sync becomes incremental.
    @questrade_account.update!(
      last_activities_sync: Time.current,
      raw_activities_payload: Array.new(QuestradeItem::Importer::MINIMUM_HISTORY_FOR_INCREMENTAL) { |i|
        { "transactionDate" => "2026-01-0#{(i % 9) + 1}", "type" => "Trades" }
      }
    )
    assert_equal (@questrade_account.last_activities_sync - 30.days).to_date,
      importer.send(:calculate_start_date, @questrade_account)
  end

  test "full-sync fallback never starts earlier than sync_start_date" do
    importer = QuestradeItem::Importer.new(@questrade_item, questrade_provider: stub_provider(accounts: []))
    @questrade_account.update!(
      sync_start_date: 6.months.ago.to_date,
      last_activities_sync: Time.current,
      raw_activities_payload: [ { "transactionDate" => "2026-01-01", "type" => "Trades" } ]
    )

    assert_equal 6.months.ago.to_date, importer.send(:calculate_start_date, @questrade_account)
  end

  private

    def link_account!
      account = @family.accounts.create!(
        name: "TFSA",
        balance: 0,
        currency: "CAD",
        accountable: Investment.new
      )
      @questrade_account.ensure_account_provider!(account)
      @questrade_account.reload
    end

    # Minimal provider double: only the calls a test exercises get stubbed with
    # real data; everything else returns an empty payload.
    def stub_provider(accounts:)
      provider = mock("questrade_provider")
      provider.stubs(:list_accounts).returns({ accounts: accounts })
      provider.stubs(:get_balances).returns({ perCurrencyBalances: [], combinedBalances: [] })
      provider.stubs(:get_holdings).returns({ positions: [] })
      provider.stubs(:get_activities).returns({ activities: [] })
      provider.stubs(:get_symbols).returns({ symbols: [] })
      provider
    end
end
