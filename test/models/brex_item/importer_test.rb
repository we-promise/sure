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

  test "first sync starts from the chosen start date" do
    chosen = Date.current - 2.years
    @brex_item.update!(sync_start_date: chosen)
    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: [ cash_account_payload ])
    provider.expects(:get_cash_transactions).with("cash_1", start_date: chosen).returns(transactions: [])

    assert BrexItem::Importer.new(@brex_item, brex_provider: provider).import[:success]
  end

  test "first sync reads the chosen start date as a day on the family calendar" do
    @family.update!(timezone: "Pacific/Auckland")
    @brex_item.update!(sync_start_date: Time.utc(2024, 3, 9, 23, 0, 0))
    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: [ cash_account_payload ])
    provider.expects(:get_cash_transactions).with("cash_1", start_date: Date.new(2024, 3, 10)).returns(transactions: [])

    assert BrexItem::Importer.new(@brex_item, brex_provider: provider).import[:success]
  end

  test "first sync never starts after today when the chosen start date is in the future" do
    @brex_item.update!(sync_start_date: 10.days.from_now)
    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: [ cash_account_payload ])
    provider.expects(:get_cash_transactions).with("cash_1", start_date: @family.local_date).returns(transactions: [])

    assert BrexItem::Importer.new(@brex_item, brex_provider: provider).import[:success]
  end

  test "first sync without a chosen start date keeps the default window" do
    captured_start = nil
    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: [ cash_account_payload ])
    provider.expects(:get_cash_transactions).with do |_id, opts|
      captured_start = opts[:start_date]
      true
    end.returns(transactions: [])

    assert BrexItem::Importer.new(@brex_item, brex_provider: provider).import[:success]
    assert captured_start >= 91.days.ago, "first-sync start date must be within 90 days"
  end

  test "resync does not go back before the chosen start date" do
    chosen = Date.current - 3.days
    @brex_item.update!(sync_start_date: chosen)
    @brex_item.stubs(:last_synced_at).returns(1.day.ago)
    @brex_account.update!(raw_transactions_payload: [ { id: "cash_tx_1", posted_at_date: Date.current.to_s } ])
    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: [ cash_account_payload ])
    provider.expects(:get_cash_transactions).with("cash_1", start_date: chosen).returns(transactions: [])

    assert BrexItem::Importer.new(@brex_item, brex_provider: provider).import[:success]
  end

  test "resync keeps the last sync buffer when it is after the chosen start date" do
    last_synced = 10.days.ago
    @brex_item.update!(sync_start_date: Date.current - 2.years)
    @brex_item.stubs(:last_synced_at).returns(last_synced)
    @brex_account.update!(raw_transactions_payload: [ { id: "cash_tx_1", posted_at_date: Date.current.to_s } ])
    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: [ cash_account_payload ])
    provider.expects(:get_cash_transactions).with("cash_1", start_date: last_synced - 7.days).returns(transactions: [])

    assert BrexItem::Importer.new(@brex_item, brex_provider: provider).import[:success]
  end

  test "a sync window still takes precedence over the chosen start date" do
    @brex_item.update!(sync_start_date: Date.current - 2.years)
    window = Date.current - 5.days
    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: [ cash_account_payload ])
    provider.expects(:get_cash_transactions).with("cash_1", start_date: window).returns(transactions: [])

    assert BrexItem::Importer.new(@brex_item, brex_provider: provider, sync_start_date: window).import[:success]
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
