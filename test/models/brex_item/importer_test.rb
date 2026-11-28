# frozen_string_literal: true

require "test_helper"

class BrexItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @brex_item = brex_items(:one)
    @account = @family.accounts.create!(
      name: "Operating Cash",
      balance: 0,
      currency: "USD",
      accountable: Depository.new(subtype: "checking")
    )
    @brex_account = @brex_item.brex_accounts.create!(
      account_id: "cash_1",
      account_kind: "cash",
      name: "Operating Cash",
      currency: "USD",
      current_balance: 0
    )
    AccountProvider.create!(account: @account, provider: @brex_account)
  end

  test "imports account discovery and fetches transactions only for linked accounts" do
    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: [ cash_account_payload, card_account_payload ])
    provider.expects(:get_cash_transactions).with("cash_1", start_date: Date.new(2026, 1, 1)).returns(
      transactions: [
        {
          id: "cash_tx_1",
          amount: { amount: 12_34, currency: "USD" },
          description: "Wire fee",
          posted_at_date: "2026-01-02"
        }
      ]
    )
    provider.expects(:get_primary_card_transactions).never

    result = BrexItem::Importer.new(@brex_item, brex_provider: provider, sync_start_date: Date.new(2026, 1, 1)).import

    assert result[:success]
    assert_equal 1, result[:accounts_updated]
    assert_equal 1, result[:accounts_created]
    assert_equal [ "cash_tx_1" ], @brex_account.reload.raw_transactions_payload.map { |tx| tx["id"] }
    assert_equal "card", @brex_item.brex_accounts.find_by!(account_id: BrexAccount.card_account_id).account_kind
  end

  test "counts only newly stored transactions as imported" do
    @brex_account.update!(
      raw_transactions_payload: [
        {
          id: "cash_tx_1",
          amount: { amount: 12_34, currency: "USD" },
          description: "Existing wire fee",
          posted_at_date: "2026-01-02"
        }
      ]
    )

    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: [ cash_account_payload ])
    provider.expects(:get_cash_transactions).with("cash_1", start_date: anything).returns(
      transactions: [
        {
          id: "cash_tx_1",
          amount: { amount: 12_34, currency: "USD" },
          description: "Existing wire fee",
          posted_at_date: "2026-01-02"
        },
        {
          id: "cash_tx_2",
          amount: { amount: 56_78, currency: "USD" },
          description: "New wire fee",
          posted_at_date: "2026-01-03"
        }
      ]
    )

    result = BrexItem::Importer.new(@brex_item, brex_provider: provider, sync_start_date: Date.new(2026, 1, 1)).import

    assert result[:success]
    assert_equal 1, result[:transactions_imported]
    assert_equal [ "cash_tx_1", "cash_tx_2" ], @brex_account.reload.raw_transactions_payload.map { |tx| tx["id"] }
  end

  test "keeps raw transaction snapshots bounded to the sync window" do
    @brex_account.update!(
      raw_transactions_payload: [
        {
          id: "old_cash_tx",
          amount: { amount: 12_34, currency: "USD" },
          description: "Old wire fee",
          posted_at_date: "2025-12-01"
        },
        {
          id: "recent_cash_tx",
          amount: { amount: 56_78, currency: "USD" },
          description: "Recent wire fee",
          posted_at_date: "2026-01-02"
        }
      ]
    )

    sync_start_date = Date.new(2026, 1, 1)
    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: [ cash_account_payload ])
    provider.expects(:get_cash_transactions).with("cash_1", start_date: sync_start_date).returns(
      transactions: [
        {
          id: "ignored_before_window",
          amount: { amount: 1_00, currency: "USD" },
          description: "Ignored old transaction",
          posted_at_date: "2025-12-31"
        },
        {
          id: "new_cash_tx",
          amount: { amount: 2_00, currency: "USD" },
          description: "New transaction",
          posted_at_date: "2026-01-03"
        }
      ]
    )

    result = BrexItem::Importer.new(@brex_item, brex_provider: provider, sync_start_date: sync_start_date).import

    assert result[:success]
    assert_equal 1, result[:transactions_imported]
    assert_equal [ "recent_cash_tx", "new_cash_tx" ], @brex_account.reload.raw_transactions_payload.map { |tx| tx["id"] }
  end

  test "uses explicit sync start date for cash and card transaction fetches" do
    card_account = @family.accounts.create!(
      name: "Brex Card",
      balance: 0,
      currency: "USD",
      accountable: CreditCard.new
    )
    brex_card_account = @brex_item.brex_accounts.create!(
      account_id: BrexAccount.card_account_id,
      account_kind: "card",
      name: "Brex Card",
      currency: "USD",
      current_balance: 0
    )
    AccountProvider.create!(account: card_account, provider: brex_card_account)

    sync_start_date = Date.new(2026, 2, 1)
    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: [ cash_account_payload, card_account_payload ])
    provider.expects(:get_cash_transactions).with("cash_1", start_date: sync_start_date).returns(transactions: [])
    provider.expects(:get_primary_card_transactions).with(start_date: sync_start_date).returns(transactions: [])

    result = BrexItem::Importer.new(
      @brex_item,
      brex_provider: provider,
      sync_start_date: sync_start_date
    ).import

    assert result[:success]
  end

  test "imports aggregate card transactions only into the selected connection" do
    first_card_account = @family.accounts.create!(
      name: "First Brex Card",
      balance: 0,
      currency: "USD",
      accountable: CreditCard.new
    )
    first_brex_card_account = @brex_item.brex_accounts.create!(
      account_id: BrexAccount.card_account_id,
      account_kind: "card",
      name: "First Brex Card",
      currency: "USD",
      current_balance: 0
    )
    AccountProvider.create!(account: first_card_account, provider: first_brex_card_account)

    second_item = BrexItem.create!(
      family: @family,
      name: "Second Brex",
      token: "second_brex_token",
      base_url: "https://api.brex.com"
    )
    second_card_account = @family.accounts.create!(
      name: "Second Brex Card",
      balance: 0,
      currency: "USD",
      accountable: CreditCard.new
    )
    second_brex_card_account = second_item.brex_accounts.create!(
      account_id: BrexAccount.card_account_id,
      account_kind: "card",
      name: "Second Brex Card",
      currency: "USD",
      current_balance: 0,
      raw_transactions_payload: [
        {
          id: "second_connection_card_tx",
          amount: { amount: 42_00, currency: "USD" },
          description: "Existing second connection card transaction",
          posted_at_date: "2026-02-01"
        }
      ]
    )
    AccountProvider.create!(account: second_card_account, provider: second_brex_card_account)

    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: [ cash_account_payload, card_account_payload ])
    provider.expects(:get_cash_transactions).with("cash_1", start_date: anything).returns(transactions: [])
    provider.expects(:get_primary_card_transactions).with(start_date: anything).returns(
      transactions: [
        {
          id: "first_connection_card_tx",
          amount: { amount: 21_00, currency: "USD" },
          description: "First connection card transaction",
          posted_at_date: "2026-02-02",
          card_id: "card_account_1"
        }
      ]
    )

    result = BrexItem::Importer.new(@brex_item, brex_provider: provider, sync_start_date: Date.new(2026, 2, 1)).import

    assert result[:success]
    assert_equal [ "first_connection_card_tx" ], first_brex_card_account.reload.raw_transactions_payload.map { |tx| tx["id"] }
    assert_equal [ "second_connection_card_tx" ], second_brex_card_account.reload.raw_transactions_payload.map { |tx| tx["id"] }
  end

  test "raises and reports snapshot persistence failures" do
    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: [ cash_account_payload ])
    @brex_item.expects(:upsert_brex_snapshot!).raises(StandardError.new("snapshot failed"))

    error = assert_raises StandardError do
      BrexItem::Importer.new(@brex_item, brex_provider: provider).import
    end

    assert_equal "snapshot failed", error.message
  end

  test "marks item as requiring update and raises on authorization errors" do
    provider = mock("brex_provider")
    provider.expects(:get_accounts).raises(
      Provider::Brex::BrexError.new("Access forbidden", :access_forbidden, http_status: 403, trace_id: "trace_123")
    )

    assert_raises(Provider::Brex::BrexError) do
      BrexItem::Importer.new(@brex_item, brex_provider: provider).import
    end

    assert @brex_item.reload.requires_update?
  end

  test "clears requires update after a clean import" do
    @brex_item.update!(status: :requires_update)

    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: [ cash_account_payload ])
    provider.expects(:get_cash_transactions).with("cash_1", start_date: anything).returns(transactions: [])

    result = BrexItem::Importer.new(@brex_item, brex_provider: provider).import

    assert result[:success]
    assert @brex_item.reload.good?
  end

  test "refreshes already discovered unlinked accounts during import" do
    unlinked_account = @brex_item.brex_accounts.create!(
      account_id: "cash_unlinked_1",
      account_kind: "cash",
      name: "Old Unlinked Cash",
      currency: "USD",
      current_balance: 1
    )

    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(
      accounts: [
        cash_account_payload,
        cash_account_payload.merge(
          id: "cash_unlinked_1",
          name: "Updated Unlinked Cash",
          current_balance: { amount: 987_65, currency: "USD" }
        )
      ]
    )
    provider.expects(:get_cash_transactions).with("cash_1", start_date: anything).returns(transactions: [])

    result = BrexItem::Importer.new(@brex_item, brex_provider: provider).import

    assert result[:success]
    assert_equal 2, result[:accounts_updated]
    assert_equal "Updated Unlinked Cash", unlinked_account.reload.name
    assert_equal BigDecimal("987.65"), unlinked_account.current_balance
  end

  test "a failed accounts fetch records a debug log entry for support" do
    provider = mock("brex_provider")
    provider.expects(:get_accounts).raises(
      Provider::Brex::BrexError.new("Brex API server error", :server_error, http_status: 500, trace_id: "trace_456")
    )

    result = nil
    assert_difference -> { DebugLogEntry.count }, 1 do
      result = BrexItem::Importer.new(@brex_item, brex_provider: provider).import
    end

    assert_not result[:success]
    entry = DebugLogEntry.recent.first
    assert_equal [ "brex", "BrexItem::Importer", "error" ], [ entry.provider_key, entry.source, entry.level ]
    assert_equal @family, entry.family
    assert_nil entry.account_provider
    assert_equal(
      { "brex_item_id" => @brex_item.id, "error_class" => "Provider::Brex::BrexError",
        "error_message" => "Brex API server error", "trace_id" => "trace_456" },
      entry.metadata
    )
  end

  test "a failed transactions fetch records a debug log entry for the account" do
    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: [ cash_account_payload ])
    provider.expects(:get_cash_transactions).raises(
      Provider::Brex::BrexError.new("Rate limit exceeded", :rate_limited, http_status: 429, trace_id: "trace_789")
    )

    result = nil
    assert_difference -> { DebugLogEntry.count }, 1 do
      result = BrexItem::Importer.new(@brex_item, brex_provider: provider).import
    end

    assert_equal 1, result[:transactions_failed]
    entry = DebugLogEntry.recent.first
    assert_equal [ "brex", "BrexItem::Importer" ], [ entry.provider_key, entry.source ]
    assert_equal @family, entry.family
    assert_equal @brex_account.account_provider, entry.account_provider
    assert_equal(
      { "brex_item_id" => @brex_item.id, "account_id" => "cash_1", "error_class" => "Provider::Brex::BrexError",
        "error_message" => "Rate limit exceeded", "trace_id" => "trace_789" },
      entry.metadata
    )
  end

  test "a failed account import records the account id in the metadata" do
    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: [ cash_account_payload ])
    provider.stubs(:get_cash_transactions).returns(transactions: [])
    BrexAccount.any_instance.stubs(:upsert_brex_snapshot!).raises(StandardError, "snapshot write failed")

    assert_difference -> { DebugLogEntry.count }, 1 do
      BrexItem::Importer.new(@brex_item, brex_provider: provider).import
    end

    entry = DebugLogEntry.recent.first
    assert_equal "Failed to import account", entry.message
    assert_equal(
      { "brex_item_id" => @brex_item.id, "account_id" => "cash_1", "error_class" => "StandardError",
        "error_message" => "snapshot write failed" },
      entry.metadata
    )
  end

  {
    "an accounts response that is not a Hash" => [ -> { [] }, "Invalid accounts response format", nil ],
    "an accounts response that cannot be parsed" => [ -> { raise JSON::ParserError, "unexpected token" }, "Failed to parse accounts response", "JSON::ParserError" ],
    "an unexpected accounts fetch error" => [ -> { raise ArgumentError, "boom" }, "Unexpected error fetching accounts", "ArgumentError" ]
  }.each do |name, (response, message, error_class)|
    test "#{name} records a debug log entry" do
      provider = Object.new
      provider.define_singleton_method(:get_accounts) { response.call }

      assert_difference -> { DebugLogEntry.where(message: message).count }, 1 do
        assert_not BrexItem::Importer.new(@brex_item, brex_provider: provider).import[:success]
      end
      assert_equal({ "error_class" => error_class }.compact, DebugLogEntry.find_by!(message: message).metadata.slice("error_class"))
    end
  end

  {
    "a transactions response that is not a Hash" => [ -> { [] }, "Invalid transactions response format", nil ],
    "a transactions response that cannot be parsed" => [ -> { raise JSON::ParserError, "unexpected token" }, "Failed to parse transactions response", "JSON::ParserError" ],
    "an unexpected transactions fetch error" => [ -> { raise ArgumentError, "boom" }, "Unexpected error fetching transactions", "ArgumentError" ]
  }.each do |name, (response, message, error_class)|
    test "#{name} records a debug log entry for the account" do
      accounts = { accounts: [ cash_account_payload ] }
      provider = Object.new
      provider.define_singleton_method(:get_accounts) { accounts }
      provider.define_singleton_method(:get_cash_transactions) { |*, **| response.call }

      result = nil
      assert_difference -> { DebugLogEntry.where(message: message).count }, 1 do
        result = BrexItem::Importer.new(@brex_item, brex_provider: provider).import
      end

      assert_equal 1, result[:transactions_failed]
      entry = DebugLogEntry.find_by!(message: message)
      assert_equal @brex_account.account_provider, entry.account_provider
      assert_equal [ "cash_1", error_class ], entry.metadata.values_at("account_id", "error_class")
    end
  end

  test "a transactions failure outside the fetch records a debug log entry for the account" do
    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: [ cash_account_payload ])
    BrexItem::Importer.any_instance.stubs(:fetch_and_store_transactions).raises(ArgumentError, "boom")

    result = nil
    assert_difference -> { DebugLogEntry.where(message: "Failed to import transactions").count }, 1 do
      result = BrexItem::Importer.new(@brex_item, brex_provider: provider).import
    end

    assert_equal 1, result[:transactions_failed]
    entry = DebugLogEntry.find_by!(message: "Failed to import transactions")
    assert_equal @brex_account.account_provider, entry.account_provider
    assert_equal [ "cash_1", "ArgumentError" ], entry.metadata.values_at("account_id", "error_class")
  end

  test "a credential failure is logged once, by the syncer, not by the importer" do
    Provider::Brex.any_instance.stubs(:get_accounts).raises(
      Provider::Brex::BrexError.new("Invalid Brex API token", :unauthorized, http_status: 401, trace_id: "trace_401")
    )
    Sentry.stubs(:capture_exception)

    assert_difference -> { DebugLogEntry.count }, 1 do
      Sync.create!(syncable: @brex_item).perform
    end

    assert_equal "BrexItem::Syncer", DebugLogEntry.recent.first.source
  end

  test "a clean import records no debug log entry" do
    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: [ cash_account_payload ])
    provider.expects(:get_cash_transactions).returns(transactions: [])

    assert_no_difference -> { DebugLogEntry.count } do
      assert BrexItem::Importer.new(@brex_item, brex_provider: provider).import[:success]
    end
  end

  private

    def cash_account_payload
      {
        id: "cash_1",
        name: "Operating Cash",
        account_kind: "cash",
        status: "ACTIVE",
        current_balance: { amount: 120_000, currency: "USD" },
        available_balance: { amount: 110_000, currency: "USD" },
        account_number: "account-last4-9012",
        routing_number: "routing-last4-0021"
      }
    end

    def card_account_payload
      {
        id: BrexAccount.card_account_id,
        name: "Brex Card",
        account_kind: "card",
        status: "ACTIVE",
        current_balance: { amount: 1_234, currency: "USD" },
        available_balance: { amount: 100_000, currency: "USD" },
        account_limit: { amount: 150_000, currency: "USD" },
        raw_card_accounts: [
          {
            id: "card_account_1",
            card_metadata: {
              pan: "test-pan-placeholder"
            }
          }
        ]
      }
    end
end
