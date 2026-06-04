require "test_helper"

class SnaptradeAccountTest < ActiveSupport::TestCase
  setup do
    @family_a = families(:dylan_family)
    @family_b = families(:empty)

    @item_a = SnaptradeItem.create!(
      family: @family_a,
      name: "Family A Broker",
      client_id: "client_a",
      consumer_key: "key_a",
      status: "good"
    )

    @item_b = SnaptradeItem.create!(
      family: @family_b,
      name: "Family B Broker",
      client_id: "client_b",
      consumer_key: "key_b",
      status: "good"
    )
  end

  test "same snaptrade_account_id can be linked under different snaptrade_items" do
    SnaptradeAccount.create!(
      snaptrade_item: @item_a,
      snaptrade_account_id: "shared_snap_uuid_1",
      name: "IRA",
      currency: "USD",
      current_balance: 5000
    )

    assert_difference "SnaptradeAccount.count", 1 do
      SnaptradeAccount.create!(
        snaptrade_item: @item_b,
        snaptrade_account_id: "shared_snap_uuid_1",
        name: "IRA",
        currency: "USD",
        current_balance: 5000
      )
    end
  end

  test "same snaptrade_account_id cannot appear twice under the same snaptrade_item" do
    SnaptradeAccount.create!(
      snaptrade_item: @item_a,
      snaptrade_account_id: "dup_snap_uuid",
      name: "Brokerage",
      currency: "USD",
      current_balance: 1000
    )

    duplicate = SnaptradeAccount.new(
      snaptrade_item: @item_a,
      snaptrade_account_id: "dup_snap_uuid",
      name: "Brokerage",
      currency: "USD",
      current_balance: 1000
    )
    refute duplicate.valid?
    assert_includes duplicate.errors[:snaptrade_account_id], "has already been taken"

    assert_raises(ActiveRecord::RecordInvalid) do
      SnaptradeAccount.create!(
        snaptrade_item: @item_a,
        snaptrade_account_id: "dup_snap_uuid",
        name: "Brokerage",
        currency: "USD",
        current_balance: 1000
      )
    end
  end

  # ---- upsert_balances! ---------------------------------------------------

  class UpsertBalancesTest < ActiveSupport::TestCase
    setup do
      @item = SnaptradeAccount.find(snaptrade_accounts(:fidelity_401k).id).snaptrade_item
      @account = accounts(:investment)
      @snaptrade_account = SnaptradeAccount.create!(
        snaptrade_item: @item,
        snaptrade_account_id: "acc_multi_currency",
        name: "Multi-Currency Brokerage",
        currency: "USD",
        current_balance: 7000
      )
      @snaptrade_account.ensure_account_provider!(@account)
    end

    test "stores primary currency cash on cash_balance and other currencies as holdings" do
      balances = [
        { cash: 6161.00, currency: { code: "USD" } },
        { cash: 10.00,   currency: { code: "CAD" } }
      ]

      assert_difference -> { @account.holdings.count }, 1 do
        @snaptrade_account.upsert_balances!(balances)
      end

      assert_equal BigDecimal("6161.00"), @snaptrade_account.reload.cash_balance

      cad_security = Security.find_by(ticker: "CASH-CAD", kind: "cash")
      assert_not_nil cad_security
      assert_equal "Cash (CAD)", cad_security.name

      cad_holding = @account.holdings.find_by(security: cad_security)
      assert_not_nil cad_holding
      assert_equal "CAD", cad_holding.currency
      assert_equal 1, cad_holding.qty
      assert_equal BigDecimal("10.00"), cad_holding.amount
      assert_equal BigDecimal("10.00"), cad_holding.price
      assert_equal Date.current, cad_holding.date
      assert_equal @snaptrade_account.account_provider.id, cad_holding.account_provider_id
    end

    test "single primary-currency balance does not create any holdings" do
      balances = [
        { cash: 1234.56, currency: { code: "USD" } }
      ]

      assert_no_difference -> { @account.holdings.count } do
        @snaptrade_account.upsert_balances!(balances)
      end

      assert_equal BigDecimal("1234.56"), @snaptrade_account.reload.cash_balance
    end

    test "skips additional currency entries with zero or nil cash" do
      balances = [
        { cash: 100.00, currency: { code: "USD" } },
        { cash: 0,      currency: { code: "EUR" } },
        { cash: nil,    currency: { code: "GBP" } }
      ]

      assert_no_difference -> { @account.holdings.count } do
        @snaptrade_account.upsert_balances!(balances)
      end

      assert_equal BigDecimal("100.00"), @snaptrade_account.reload.cash_balance
    end

    test "skips currency entries whose code is not a 3-letter ISO code" do
      balances = [
        { cash: 100.00, currency: { code: "USD" } },
        { cash: 5.00,   currency: { code: "USDC" } },
        { cash: 7.00,   currency: { code: "us" } }
      ]

      assert_no_difference -> { @account.holdings.count } do
        @snaptrade_account.upsert_balances!(balances)
      end

      refute Security.exists?(ticker: "CASH-USDC")
    end

    test "removes stale synthetic cash holdings when a currency drops to zero" do
      @snaptrade_account.upsert_balances!([
        { cash: 100.00, currency: { code: "USD" } },
        { cash: 25.00,  currency: { code: "CAD" } },
        { cash: 50.00,  currency: { code: "EUR" } }
      ])

      cash_scope = @account.holdings.joins(:security).where(securities: { kind: "cash" })
      assert_equal 2, cash_scope.where(date: Date.current).count

      @snaptrade_account.upsert_balances!([
        { cash: 100.00, currency: { code: "USD" } },
        { cash: 25.00,  currency: { code: "CAD" } }
      ])

      cad_security = Security.find_by(ticker: "CASH-CAD")
      eur_security = Security.find_by(ticker: "CASH-EUR")

      assert @account.holdings.exists?(security: cad_security, date: Date.current)
      refute @account.holdings.exists?(security: eur_security, date: Date.current)
    end

    test "removes synthetic cash holding when the currency is absent on next sync" do
      @snaptrade_account.upsert_balances!([
        { cash: 100.00, currency: { code: "USD" } },
        { cash: 25.00,  currency: { code: "CAD" } }
      ])

      cad_security = Security.find_by(ticker: "CASH-CAD")
      assert @account.holdings.exists?(security: cad_security, date: Date.current)

      @snaptrade_account.upsert_balances!([
        { cash: 100.00, currency: { code: "USD" } }
      ])

      refute @account.holdings.exists?(security: cad_security, date: Date.current)
    end

    test "does not touch holdings when account is not linked" do
      unlinked = SnaptradeAccount.create!(
        snaptrade_item: @item,
        snaptrade_account_id: "acc_unlinked",
        name: "Unlinked",
        currency: "USD",
        current_balance: 0
      )

      assert_nil unlinked.current_account

      assert_nothing_raised do
        unlinked.upsert_balances!([
          { cash: 50.00, currency: { code: "USD" } },
          { cash: 10.00, currency: { code: "CAD" } }
        ])
      end

      assert_equal BigDecimal("50.00"), unlinked.reload.cash_balance
    end
  end
end
