require "test_helper"

class AccountTradeRepublicCreationTest < ActiveSupport::TestCase
  setup do
    @item = trade_republic_items(:no_session_item)
  end

  test "maps each Trade Republic kind to a Sure accountable and subtype" do
    expectations = {
      "portfolio" => [ "Investment", "brokerage", "Trade Republic Portfolio" ],
      "pea" => [ "Investment", "pea", "Trade Republic PEA" ],
      "cash" => [ "Depository", "checking", "Trade Republic Cash" ],
      "crypto" => [ "Crypto", "exchange", "Trade Republic Crypto" ]
    }

    expectations.each do |kind, (accountable_type, subtype, default_name)|
      provider_account = @item.trade_republic_accounts.create!(
        kind: kind, name: nil, trade_republic_account_id: "SEC-#{kind}", currency: "EUR"
      )

      account = Account.create_from_trade_republic_account(provider_account)

      assert_equal accountable_type, account.accountable_type, kind
      assert_equal subtype, account.accountable.subtype, kind
      assert_equal default_name, account.name, kind
      assert_equal @item.family, account.family, kind
    end
  end

  test "TRADE_REPUBLIC_ACCOUNT_TYPES tags the PEA as an Investment pea wrapper" do
    assert_equal [ "Investment", "pea", "Trade Republic PEA" ], Account::TRADE_REPUBLIC_ACCOUNT_TYPES["pea"]
    assert_equal [ "Investment", "brokerage", "Trade Republic Portfolio" ], Account::TRADE_REPUBLIC_ACCOUNT_TYPES["portfolio"]
    assert_equal [ "Depository", "checking", "Trade Republic Cash" ], Account::TRADE_REPUBLIC_ACCOUNT_TYPES["cash"]
    assert_equal [ "Crypto", "exchange", "Trade Republic Crypto" ], Account::TRADE_REPUBLIC_ACCOUNT_TYPES["crypto"]
    assert_equal "brokerage", Account::TRADE_REPUBLIC_ACCOUNT_TYPES["portfolio"][1]
  end

  test "uses the provider account name when it is present" do
    provider_account = @item.trade_republic_accounts.create!(
      kind: "pea", name: "My French PEA", trade_republic_account_id: "SEC-PEA-NAMED", currency: "EUR"
    )

    account = Account.create_from_trade_republic_account(provider_account)

    assert_equal "My French PEA", account.name
    assert_equal "pea", account.accountable.subtype
  end
end
