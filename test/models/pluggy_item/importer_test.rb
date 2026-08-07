require "test_helper"

class PluggyItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @pluggy_item = pluggy_items(:one)
    @pluggy_item.stubs(:pluggy_item_id).returns("item-123")
    @provider = stub("PluggyItem::Provider")
    @pluggy_item.stubs(:pluggy_provider).returns(@provider)
  end

  test "import fetches item, accounts, transactions, investments and upserts accounts" do
    @provider.expects(:get_item).returns(
      "connector" => { "name" => "Example Bank", "website_url" => "https://bank.example" }
    )
    @provider.expects(:get_accounts).returns([
      { "id" => "acc-1", "name" => "Conta Corrente", "type" => "checking",
        "currencyCode" => "BRL", "balance"  => 100.0, "status" => "ACTIVE" }
    ])
    @provider.expects(:get_investments).returns([
      { "id" => "inv-1", "code" => "PETR4", "quantity" => 10, "price" => 30.0, "currencyCode" => "BRL" }
    ])
    @provider.expects(:get_investment_transactions).with(investment_id: "inv-1").returns([])
    @provider.expects(:get_account_transactions).with(account_id: "acc-1").returns([
      { "id" => "tx-1", "amount" => -50.0, "currencyCode" => "BRL",
        "date" => "2026-01-01", "status" => "POSTED", "name" => "Lanchonete" }
    ])

    # Checking-only /accounts + 1 investment → importer synthesizes an
    # investment container; both rows processed.
    PluggyAccount::Processor.any_instance.expects(:process).returns(true).twice

    assert_difference "PluggyAccount.count", 2 do # 1 real /accounts + 1 synthetic
      result = PluggyItem::Importer.new(@pluggy_item, pluggy_provider: @provider).import
      assert_equal 1, result[:accounts]
      assert_equal 1, result[:transactions]
      assert_equal 1, result[:investments]
    end

    @pluggy_item.reload
    assert_equal "Example Bank", @pluggy_item.institution_name
    assert_equal "bank.example", @pluggy_item.institution_domain
  end

  test "import flips status to requires_update on AuthenticationError" do
    @provider.expects(:get_item).raises(Provider::Pluggy::AuthenticationError.new("401"))

    assert_no_difference "PluggyAccount.count" do
      assert_raises(Provider::Pluggy::AuthenticationError) do
        PluggyItem::Importer.new(@pluggy_item, pluggy_provider: @provider).import
      end
    end

    assert_equal "requires_update", @pluggy_item.reload.status
  end

  test "import isolates a per-account failure and continues importing the rest" do
    # One bad account must not abort the whole import; acc-bad is recorded then
    # the loop continues. Mirrors EnableBanking/Lunchflow.
    @provider.expects(:get_item).returns("connector" => { "name" => "Nubank" })
    @provider.expects(:get_accounts).returns([
      { "id" => "acc-bad", "name" => "Quebrada", "type" => "checking",
        "currencyCode" => "BRL", "balance" => 0.0, "status" => "ACTIVE" },
      { "id" => "acc-good", "name" => "Boa", "type" => "checking",
        "currencyCode" => "BRL", "balance" => 999.0, "status" => "ACTIVE" }
    ])
    @provider.expects(:get_investments).returns([])
    # acc-bad blows up mid-import (transactions fetch); acc-good succeeds.
    @provider.expects(:get_account_transactions).with(account_id: "acc-bad").raises(StandardError.new("upstream 500"))
    @provider.expects(:get_account_transactions).with(account_id: "acc-good").returns([])

    # Only acc-good reaches Processor#process — acc-bad is rescued first.
    PluggyAccount::Processor.any_instance.expects(:process).once

    # Block matcher: a Regexp value never == a String, so hash_including(message: /acc-bad/)
    # can't match (see yahoo_finance_test.rb:267).
    DebugLogEntry.expects(:capture).with do |attributes|
      attributes[:category] == "provider_sync_error" &&
        attributes[:level] == "warn" &&
        attributes[:provider_key] == "pluggy" &&
        attributes[:message].to_s.include?("acc-bad")
    end

    assert_difference "PluggyAccount.count", 2 do
      result = PluggyItem::Importer.new(@pluggy_item, pluggy_provider: @provider).import
      assert_equal 2, result[:accounts]
      assert_equal 1, result[:processed].size
      assert_equal 1, result[:errors].size
      assert_equal "acc-bad", result[:errors].first[:account_id]
      assert_equal "StandardError", result[:errors].first[:error_class]
    end
  end

  test "synthesizes an investment PluggyAccount when /accounts has no investment-type account" do
    # Dashboard shows investments but /accounts returns only credit/checking
    # → item-scoped investments have no container and never surface in
    # unlinked_pluggy_accounts.
    @provider.expects(:get_item).returns("connector" => { "name" => "Nubank" })
    @provider.expects(:get_accounts).returns([
      { "id" => "acc-credit", "name" => "Cartão", "type" => "credit_card",
        "currencyCode" => "BRL", "balance" => -500.0, "status" => "ACTIVE" },
      { "id" => "acc-bank", "name" => "Conta", "type" => "checking",
        "currencyCode" => "BRL", "balance" => 1234.0, "status" => "ACTIVE" }
    ])
    @provider.expects(:get_investments).returns([
      { "id" => "inv-1", "code" => "PETR4", "quantity" => 100, "price" => 35.0, "currencyCode" => "BRL" },
      { "id" => "inv-2", "code" => "VALE3", "quantity" => 50, "price" => 60.0, "currencyCode" => "BRL" }
    ])
    @provider.expects(:get_investment_transactions).with(investment_id: "inv-1").returns([])
    @provider.expects(:get_investment_transactions).with(investment_id: "inv-2").returns([])
    @provider.expects(:get_account_transactions).with(account_id: "acc-credit").returns([])
    @provider.expects(:get_account_transactions).with(account_id: "acc-bank").returns([])

    PluggyAccount::Processor.any_instance.stubs(:process).returns(true)

    assert_difference "PluggyAccount.count", 3 do # 2 real /accounts + 1 synthetic
      PluggyItem::Importer.new(@pluggy_item, pluggy_provider: @provider).import
    end

    synthetic = @pluggy_item.pluggy_accounts.find_by(
      pluggy_account_id: "synthetic-investment-#{@pluggy_item.id}"
    )
    assert_not_nil synthetic, "expected a synthesized investment container PluggyAccount"
    assert_equal "investment", synthetic.account_type
    assert_equal 2, synthetic.raw_holdings_payload.size
    assert synthetic.activities_fetch_pending
    # Unlinked → surfaces in the linkage UI list, ready to link as an Investment account.
    assert_includes @pluggy_item.unlinked_pluggy_accounts, synthetic
  end

  # Regression for the investment double-count: investments are item-scoped, so the
  # snapshot attaches to ONE container only — not every investment-type account
  # (else HoldingsProcessor re-imports the rows under each account_provider_id and
  # the balance over-reports by the count of investment-type accounts).
  test "attaches the item holdings snapshot to ONE investment container — not to every investment-type account" do
    @provider.expects(:get_item).returns("connector" => { "name" => "Broker" })
    @provider.expects(:get_accounts).returns([
      { "id" => "inv-a", "name" => "Ações Alpha", "type" => "investment",
        "currencyCode" => "BRL", "balance" => 0.0, "status" => "ACTIVE" },
      { "id" => "inv-b", "name" => "Ações Beta", "type" => "investment",
        "currencyCode" => "BRL", "balance" => 0.0, "status" => "ACTIVE" },
      { "id" => "chk-1", "name" => "Corrente", "type" => "checking",
        "currencyCode" => "BRL", "balance" => 500.0, "status" => "ACTIVE" }
    ])
    @provider.expects(:get_investments).returns([
      { "id" => "inv-1", "code" => "PETR4", "quantity" => 100, "price" => 35.0, "currencyCode" => "BRL" },
      { "id" => "inv-2", "code" => "VALE3", "quantity" => 50, "price" => 60.0, "currencyCode" => "BRL" }
    ])
    @provider.expects(:get_investment_transactions).with(investment_id: "inv-1").returns([])
    @provider.expects(:get_investment_transactions).with(investment_id: "inv-2").returns([])
    @provider.expects(:get_account_transactions).with(account_id: "inv-a").returns([])
    @provider.expects(:get_account_transactions).with(account_id: "inv-b").returns([])
    @provider.expects(:get_account_transactions).with(account_id: "chk-1").returns([])

    PluggyAccount::Processor.any_instance.stubs(:process).returns(true)

    # 3 real /accounts rows; the first investment-type account (inv-a) is the
    # container, so synthesis is suppressed.
    assert_difference "PluggyAccount.count", 3 do
      PluggyItem::Importer.new(@pluggy_item, pluggy_provider: @provider).import
    end

    inv_a = @pluggy_item.pluggy_accounts.find_by(pluggy_account_id: "inv-a")
    inv_b = @pluggy_item.pluggy_accounts.find_by(pluggy_account_id: "inv-b")

    # inv-a is the container: full snapshot + activities-pending flag.
    assert_equal 2, inv_a.raw_holdings_payload.size,
                 "first investment-type account should carry the full item holdings snapshot"
    assert inv_a.activities_fetch_pending,
           "first investment-type account is the container and flags activities pending"

    # inv-b must NOT carry the snapshot — else HoldingsProcessor re-imports the rows
    # under a second account_provider_id and double-counts.
    assert_empty inv_b.raw_holdings_payload,
                "second investment-type account must not duplicate the item holdings snapshot"
    assert_not inv_b.activities_fetch_pending,
               "second investment-type account must not be marked the activities container"

    # Real container present → synthesis must not have fired.
    assert_nil @pluggy_item.pluggy_accounts.find_by(
      pluggy_account_id: "synthetic-investment-#{@pluggy_item.id}"
    ), "real investment container present — synthesis must not have fired"
  end

  # /accounts order is unstable. A "first wins" container pick would, on a
  # reorder between syncs, re-snapshot the new first account and leave the
  # deposed one holding a stale snapshot (upsert_from_pluggy! does not clear
  # raw_holdings_payload; import_holding keys rows by account_provider_id with
  # delete_future_holdings: false → stale rows persist and double-count once both
  # link). Container pick must be sticky: prefer the existing carrier, else a
  # stable sort key. Runs the importer TWICE (transactional fixtures persist
  # run-1 into run-2) with the investment-type accounts SWAPPED and asserts the
  # container does NOT follow the reorder.
  test "investment container is sticky across syncs — /accounts order instability does not move the snapshot" do
    accounts_run_1 = [
      { "id" => "inv-a", "name" => "Ações Alpha", "type" => "investment",
        "currencyCode" => "BRL", "balance" => 0.0, "status" => "ACTIVE" },
      { "id" => "inv-b", "name" => "Ações Beta", "type" => "investment",
        "currencyCode" => "BRL", "balance" => 0.0, "status" => "ACTIVE" },
      { "id" => "chk-1", "name" => "Corrente", "type" => "checking",
        "currencyCode" => "BRL", "balance" => 500.0, "status" => "ACTIVE" }
    ]
    # Run 2: SAME accounts, investment order SWAPPED — inv-b now precedes inv-a.
    # The sticky pick must keep inv-a as the container.
    accounts_run_2 = [
      { "id" => "inv-b", "name" => "Ações Beta", "type" => "investment",
        "currencyCode" => "BRL", "balance" => 0.0, "status" => "ACTIVE" },
      { "id" => "inv-a", "name" => "Ações Alpha", "type" => "investment",
        "currencyCode" => "BRL", "balance" => 0.0, "status" => "ACTIVE" },
      { "id" => "chk-1", "name" => "Corrente", "type" => "checking",
        "currencyCode" => "BRL", "balance" => 500.0, "status" => "ACTIVE" }
    ]
    investments = [
      { "id" => "inv-1", "code" => "PETR4", "quantity" => 100, "price" => 35.0, "currencyCode" => "BRL" },
      { "id" => "inv-2", "code" => "VALE3", "quantity" => 50, "price" => 60.0, "currencyCode" => "BRL" }
    ]

    @provider.expects(:get_item).returns("connector" => { "name" => "Broker" }).twice
    # `.returns(a, b)` defaults to `.once`; `.twice` pins cardinality to the 2
    # imports AND sequences run-1 payload → run-2 payload (order matters here).
    @provider.expects(:get_accounts).returns(accounts_run_1, accounts_run_2).twice
    @provider.expects(:get_investments).returns(investments).twice
    @provider.expects(:get_investment_transactions).with(investment_id: "inv-1").returns([]).twice
    @provider.expects(:get_investment_transactions).with(investment_id: "inv-2").returns([]).twice
    @provider.expects(:get_account_transactions).with(account_id: "inv-a").returns([]).twice
    @provider.expects(:get_account_transactions).with(account_id: "inv-b").returns([]).twice
    @provider.expects(:get_account_transactions).with(account_id: "chk-1").returns([]).twice

    PluggyAccount::Processor.any_instance.stubs(:process).returns(true)

    # Run 1: fresh sync, no existing carrier → stable-sort fallback lands on
    # inv-a (lexically smallest investment-type id). inv-a becomes the container.
    assert_difference "PluggyAccount.count", 3 do
      PluggyItem::Importer.new(@pluggy_item, pluggy_provider: @provider).import
    end
    inv_a = @pluggy_item.pluggy_accounts.find_by(pluggy_account_id: "inv-a")
    inv_b = @pluggy_item.pluggy_accounts.find_by(pluggy_account_id: "inv-b")
    assert_equal 2, inv_a.raw_holdings_payload.size, "run 1: inv-a is the container"
    assert inv_a.activities_fetch_pending, "run 1: inv-a flags activities pending"
    assert_empty inv_b.raw_holdings_payload, "run 1: inv-b carries no snapshot"

    # Run 2: SAME accounts, investment order SWAPPED (inv-b first). The sticky
    # pick must keep inv-a as the container — it already carries the snapshot —
    # rather than following the new /accounts order to inv-b.
    assert_no_difference "PluggyAccount.count" do
      PluggyItem::Importer.new(@pluggy_item, pluggy_provider: @provider).import
    end
    inv_a.reload
    inv_b.reload

    # Exactly ONE container carries the snapshot, and it is STILL inv-a (sticky)
    # — not inv-b, despite inv-b now being first.
    carriers = @pluggy_item.pluggy_accounts
      .where(account_type: "investment")
      .where("jsonb_array_length(raw_holdings_payload) > 0")
    assert_equal 1, carriers.count, "run 2: exactly one container carries the snapshot (no stale duplicate)"
    assert_equal "inv-a", carriers.first.pluggy_account_id,
                 "run 2: inv-a remains the container across the /accounts order swap (sticky pick)"

    # inv-a keeps the snapshot + activities-pending flag (sticky — did not move).
    assert_equal 2, inv_a.raw_holdings_payload.size,
                 "run 2: inv-a must remain the container despite inv-b now being first in /accounts"
    assert inv_a.activities_fetch_pending, "run 2: inv-a keeps the activities-pending flag"

    # inv-b must NOT have inherited the snapshot from the reorder — otherwise it
    # becomes a SECOND carrier and (once linked) double-counts.
    assert_empty inv_b.raw_holdings_payload,
                 "run 2: inv-b must not become the container just because /accounts reordered it first"
    assert_not inv_b.activities_fetch_pending,
               "run 2: inv-b must not be marked the activities container"

    # Real container present → synthesis must not have fired.
    assert_nil @pluggy_item.pluggy_accounts.find_by(
      pluggy_account_id: "synthetic-investment-#{@pluggy_item.id}"
    ), "real investment container present — synthesis must not have fired"
  end
end
