require "test_helper"

class TradeRepublicAccountTest < ActiveSupport::TestCase
  setup do
    @item = trade_republic_items(:no_session_item)
    @item.trade_republic_accounts.destroy_all
    @family = @item.family
  end

  test "kind sets split securities from cash accounts" do
    assert_includes TradeRepublicAccount::SECURITIES_KINDS, "portfolio"
    assert_includes TradeRepublicAccount::SECURITIES_KINDS, "pea"
    assert_includes TradeRepublicAccount::SECURITIES_KINDS, "crypto"
    assert_not_includes TradeRepublicAccount::SECURITIES_KINDS, "cash"
    assert_equal %w[cash], TradeRepublicAccount::CASH_KINDS
  end

  test "predicates classify portfolio pea cash and crypto" do
    portfolio = build_account("portfolio")
    pea = build_account("pea")
    cash = build_account("cash")
    crypto = build_account("crypto")

    assert portfolio.holds_securities?
    assert pea.holds_securities?
    assert crypto.holds_securities?
    refute cash.holds_securities?

    assert cash.cash_like?
    refute pea.cash_like?
    refute portfolio.cash_like?

    assert cash.cash_holding?
    assert pea.cash_holding?
    refute portfolio.cash_holding?
    refute crypto.cash_holding?
  end

  test "envelope kind and sibling kinds distinguish the PEA wrapper" do
    pea = build_account("pea")
    portfolio = build_account("portfolio")
    cash = build_account("cash")

    assert_equal "pea", pea.envelope_kind
    assert_equal "portfolio", portfolio.envelope_kind
    assert_equal "portfolio", cash.envelope_kind

    assert_nil pea.cash_sibling_kind
    assert_equal "cash", portfolio.cash_sibling_kind

    assert_equal "portfolio", cash.securities_sibling_kind
    assert_nil portfolio.securities_sibling_kind
    assert_nil pea.securities_sibling_kind
  end

  test "pea positions come from its own snapshot" do
    positions = [ { "isin" => "IE00B4L5Y983", "quantity" => "1", "price" => "250" } ]
    pea = @item.trade_republic_accounts.create!(
      kind: "pea", name: "PEA", trade_republic_account_id: "SEC-PEA",
      currency: "EUR", raw_positions_payload: positions
    )

    assert_equal positions, pea.positions
  end

  test "account_balance adds the PEA cash pocket" do
    pea = @item.trade_republic_accounts.create!(
      kind: "pea", name: "PEA", trade_republic_account_id: "SEC-PEA",
      currency: "EUR", current_balance: BigDecimal("1000"), cash_balance: BigDecimal("50")
    )

    assert_equal BigDecimal("1050"), pea.account_balance
  end

  test "account_balance leaves a plain portfolio snapshot untouched" do
    portfolio = @item.trade_republic_accounts.create!(
      kind: "portfolio", name: "Portfolio", trade_republic_account_id: "SEC-CTO",
      currency: "EUR", current_balance: BigDecimal("1000")
    )

    assert_equal BigDecimal("1000"), portfolio.account_balance
  end

  test "account_balance subtracts a linked crypto account from the portfolio" do
    portfolio = @item.trade_republic_accounts.create!(
      kind: "portfolio", name: "Portfolio", trade_republic_account_id: "SEC-CTO",
      currency: "EUR", current_balance: BigDecimal("1000")
    )
    crypto = @item.trade_republic_accounts.create!(
      kind: "crypto", name: "Crypto", trade_republic_account_id: "crypto:SEC-CTO",
      currency: "EUR", current_balance: BigDecimal("200")
    )
    crypto_sure = @family.accounts.create!(
      name: "Trade Republic Crypto", balance: 0, currency: "EUR",
      accountable: Crypto.new(subtype: "exchange")
    )
    crypto.ensure_account_provider!(crypto_sure)

    assert crypto.reload.crypto_split?
    assert_equal BigDecimal("800"), portfolio.reload.account_balance
  end

  private

    def build_account(kind)
      TradeRepublicAccount.new(
        trade_republic_item: @item,
        kind: kind,
        name: kind.capitalize,
        currency: "EUR"
      )
    end
end
