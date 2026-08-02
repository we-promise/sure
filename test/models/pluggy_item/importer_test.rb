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

    # The single /accounts row is checking-only, but the item has 1 investment,
    # so the importer synthesizes a 2nd investment-typed PluggyAccount container
    # (see Fix A). Both rows are processed.
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
    # Fix #5: one bad account must not abort the whole item import. The failing
    # account is recorded in result[:errors] + DebugLogEntry.capture (so /settings/debug
    # surfaces it), then the loop continues to the remaining accounts. Mirrors the
    # EnableBanking/Lunchflow importer isolation pattern.
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

    # Only the surviving account reaches Processor#process — acc-bad is rescued first.
    PluggyAccount::Processor.any_instance.expects(:process).once

    # Block matcher (not hash_including): a Regexp value never == a String, so
    # hash_including(message: /acc-bad/) can't match. Matches the yahoo_finance
    # precedent (test/models/provider/yahoo_finance_test.rb:267).
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
    # Reproduces the reported bug: Pluggy's dashboard shows investments, but
    # /accounts returns only credit/checking (NO investment-type entry), so the
    # item-scoped investments have no PluggyAccount container. With no container
    # row they never appear in unlinked_pluggy_accounts and the user can never
    # link them — hence "investments didn't arrive" + "no accounts yet".
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
    # Only the two real /accounts rows are fetched for banking transactions;
    # the synthetic container has no real Pluggy account id to query.
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
    # Unlinked → surfaces in the account-linkage UI list, ready for the user to
    # link as an Investment account (after which HoldingsProcessor imports them).
    assert_includes @pluggy_item.unlinked_pluggy_accounts, synthetic
  end
end
