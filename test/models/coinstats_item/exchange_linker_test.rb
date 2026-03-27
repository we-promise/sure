require "test_helper"

class CoinstatsItem::ExchangeLinkerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(currency: "EUR")
    @coinstats_item = CoinstatsItem.create!(
      family: @family,
      name: "Test CoinStats Connection",
      api_key: "test_api_key_123"
    )
  end

  def success_response(data)
    Provider::Response.new(success?: true, data: data, error: nil)
  end

  test "link creates one exchange portfolio account with embedded coins" do
    Provider::Coinstats.any_instance.expects(:exchange_options).returns([
      {
        connection_id: "bitvavo",
        name: "Bitvavo",
        icon: "https://example.com/bitvavo.png",
        connection_fields: [
          { key: "apiKey", name: "API Key" },
          { key: "apiSecret", name: "API Secret" }
        ]
      }
    ])

    Provider::Coinstats.any_instance.expects(:connect_portfolio_exchange)
      .with(
        connection_id: "bitvavo",
        connection_fields: { "apiKey" => "key", "apiSecret" => "secret" },
        name: "Bitvavo Portfolio"
      )
      .returns(success_response({ portfolioId: "portfolio_123" }))

    Provider::Coinstats.any_instance.expects(:list_portfolio_coins)
      .with(portfolio_id: "portfolio_123")
      .returns([
        {
          coin: { identifier: "bitcoin", symbol: "BTC", name: "Bitcoin" },
          count: "0.00335845",
          price: { EUR: "57950.0491" }
        },
        {
          coin: { identifier: "ethereum", symbol: "ETH", name: "Ethereum" },
          count: "0.05580825",
          price: { EUR: "1728.952252246" }
        },
        {
          coin: { identifier: "FiatCoin:eur", symbol: "EUR", name: "Euro", isFiat: true },
          count: "2.58",
          price: { EUR: "1" }
        }
      ])

    @coinstats_item.expects(:sync_later).once

    assert_difference [ "CoinstatsAccount.count", "Account.count", "AccountProvider.count" ], 1 do
      result = CoinstatsItem::ExchangeLinker.new(
        @coinstats_item,
        connection_id: "bitvavo",
        connection_fields: { "apiKey" => "key", "apiSecret" => "secret" }
      ).link

      assert result.success?
      assert_equal 1, result.created_count
    end

    @coinstats_item.reload
    assert_equal "portfolio_123", @coinstats_item.exchange_portfolio_id

    coinstats_account = @coinstats_item.coinstats_accounts.last
    assert coinstats_account.exchange_portfolio_account?
    assert_equal "Bitvavo", coinstats_account.name
    assert_equal "exchange_portfolio:portfolio_123", coinstats_account.account_id
    assert_equal 3, coinstats_account.raw_payload["coins"].size

    account = coinstats_account.account
    assert_equal "Bitvavo", account.name
    assert_equal "EUR", account.currency
    assert_in_delta 293.69214193130284, account.balance.to_f, 0.0001
    assert_in_delta 2.58, account.cash_balance.to_f, 0.0001
  end
end
