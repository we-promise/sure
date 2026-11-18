require "test_helper"
require "ostruct"

# The provider mapping and `store_constituents` do nothing on their own: unless
# a caller passes `include_constituents: true`, `constituents_fetched_at` stays
# nil for every security and the table never fills.
#
# These assert the opt-in at the two call sites that walk every security, which
# is the only place it can come from.
class FundConstituentIngestionTest < ActiveSupport::TestCase
  include ProviderTestHelper

  # Both tests drive the importer end to end against a stubbed provider and
  # assert the CONSTITUENTS LAND, rather than asserting the keyword is passed.
  # A signature assertion would pass even if the gate downstream refused the
  # request.
  test "a fund's holdings land in the table when the per-account importer runs" do
    account = accounts(:investment)
    fund = Security.create!(ticker: "VWRA", exchange_operating_mic: "XLON", country_code: "GB")
    account.holdings.create!(
      security: fund, date: Date.current, qty: 1, price: 100, amount: 100, currency: "USD"
    )
    # `import_security_prices` opens with `return unless Security.provider`, and
    # no securities provider is configured in the test environment -- without
    # this the importer is a no-op and the test asserts nothing at all.
    Security.stubs(:provider).returns(provider_returning_holdings)
    Security.any_instance.stubs(:import_provider_prices).returns(0)
    Security.any_instance.stubs(:price_data_provider).returns(provider_returning_holdings)

    Account::MarketDataImporter.new(account).import_security_prices

    assert_equal %w[MSFT], fund.reload.constituents.pluck(:ticker),
                 "the importer ran but no constituents were stored, so look-through stays inert"
    assert_not_nil fund.constituents_fetched_at
  end

  test "a fund's holdings land in the table when the family importer runs" do
    account = accounts(:investment)
    fund = Security.create!(ticker: "VWRA", exchange_operating_mic: "XLON", country_code: "GB")
    account.holdings.create!(
      security: fund, date: Date.current, qty: 1, price: 100, amount: 100, currency: "USD"
    )
    # `import_security_prices` opens with `return unless Security.provider`, and
    # no securities provider is configured in the test environment -- without
    # this the importer is a no-op and the test asserts nothing at all.
    # This importer guards on `Security.providers.any?` rather than
    # `Security.provider`, so it needs its own stub or it logs and returns.
    Security.stubs(:providers).returns([ provider_returning_holdings ])
    Security.any_instance.stubs(:import_provider_prices).returns(0)
    Security.any_instance.stubs(:price_data_provider).returns(provider_returning_holdings)

    MarketDataImporter.new(mode: :snapshot).import_security_prices

    assert_equal %w[MSFT], fund.reload.constituents.pluck(:ticker),
                 "the family-wide importer stores no constituents, so look-through stays inert"
    # The same gate the per-account test checks. Asserting the rows without the
    # timestamp would leave the gate's half of the opt-in untested.
    assert_not_nil fund.constituents_fetched_at
  end

  # A malformed holdings list would raise out of
  # `import_provider_details`, and this loop has no rescue, so every security
  # after the fund would lose its prices on every run. The other security's prices
  # are what this asserts, not the fund's own rows.
  test "a fund with a malformed holdings list does not stop prices for the next security" do
    family = Family.create!(name: "Smith", currency: "USD")
    account = family.accounts.create!(name: "Brokerage", currency: "USD", balance: 0, accountable: Investment.new)
    fund = Security.create!(ticker: "BADF", exchange_operating_mic: "XLON")
    stock = Security.create!(ticker: "GOOD", exchange_operating_mic: "XNAS")
    trade_date = 10.days.ago.to_date
    [ fund, stock ].each do |security|
      account.entries.create!(
        name: "Buy #{security.ticker}", date: trade_date, amount: 100, currency: "USD",
        entryable: Trade.new(security: security, qty: 1, price: 100, currency: "USD",
                             investment_activity_label: "Buy")
      )
    end
    # The fund must be reached first, or the stock is priced before anything
    # raises and the test proves nothing.
    assert_equal [ fund.id, stock.id ], account.trades.pluck(:security_id).uniq,
                 "precondition: the fund is not first in the importer's loop"

    provider = capable_provider("provider")
    provider.stubs(:class).returns(Provider::TwelveData)
    provider.stubs(:fetch_security_prices).returns(provider_success_response([]))
    provider.stubs(:fetch_security_prices).with(has_entry(symbol: "GOOD")).returns(
      provider_success_response([ OpenStruct.new(security: stock, date: trade_date, price: 100, currency: "USD") ])
    )
    malformed = Provider::SecurityConcept::SecurityInfo.new(
      symbol: "BADF", name: "Bad Fund", links: nil, logo_url: "logo", description: nil,
      kind: "ETF", exchange_operating_mic: "XLON",
      constituents: [ { ticker: "AAA", weight: 5 }, { ticker: "AAA", weight: 3 } ]
    )
    provider.stubs(:fetch_security_info).returns(provider_success_response(OpenStruct.new(name: "Good", logo_url: "logo")))
    provider.stubs(:fetch_security_info).with(has_entry(symbol: "BADF")).returns(provider_success_response(malformed))
    Security.stubs(:provider).returns(provider)
    Security.any_instance.stubs(:price_data_provider).returns(provider)

    # The importer fills forward from the one provider price, so the count is
    # asserted to rise rather than pinned to a figure the filler decides.
    before = Security::Price.where(security: stock).count
    Account::MarketDataImporter.new(account).import_security_prices
    assert_operator Security::Price.where(security: stock).count, :>, before,
                    "the security after the malformed fund received no prices"
    assert_not_nil fund.reload.constituents_fetched_at
  end

  # The same halt through the family-wide loop, which has no rescue either.
  # `find_each` walks securities by id, so the fund is given the lowest id to
  # be reached before the stock; the stock picking up its name from its own
  # details fetch is what shows the loop carried on past the fund.
  test "a fund with a malformed holdings list does not stop the family importer at that fund" do
    fund = Security.create!(id: "00000000-0000-0000-0000-000000000001", ticker: "BADF", exchange_operating_mic: "XLON")
    stock = Security.create!(id: "ffffffff-ffff-ffff-ffff-ffffffffffff", ticker: "GOOD", exchange_operating_mic: "XNAS")
    assert_equal fund.id, Security.online.order(:id).first.id, "precondition: the fund is not first in the importer's loop"
    # Holdings are only asked for securities an account holds.
    [ fund, stock ].each do |security|
      accounts(:investment).holdings.create!(
        security: security, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD"
      )
    end
    assert_nil stock.name

    provider = capable_provider("provider")
    provider.stubs(:class).returns(Provider::TwelveData)
    malformed = Provider::SecurityConcept::SecurityInfo.new(
      symbol: "BADF", name: "Bad Fund", links: nil, logo_url: "logo", description: nil,
      kind: "ETF", exchange_operating_mic: "XLON",
      constituents: [ { ticker: "AAA", weight: 5 }, { ticker: "AAA", weight: 3 } ]
    )
    provider.stubs(:fetch_security_info).returns(provider_success_response(OpenStruct.new(name: "Good", logo_url: "logo")))
    provider.stubs(:fetch_security_info).with(has_entry(symbol: "BADF")).returns(provider_success_response(malformed))
    Security.stubs(:providers).returns([ provider ])
    Security.any_instance.stubs(:import_provider_prices).returns(0)
    Security.any_instance.stubs(:price_data_provider).returns(provider)

    MarketDataImporter.new(mode: :snapshot).import_security_prices

    assert_equal "Good", stock.reload.name, "the security after the malformed fund was never reached"
    assert_not_nil fund.reload.constituents_fetched_at
  end

  private
    def provider_returning_holdings
      info = Provider::SecurityConcept::SecurityInfo.new(
        symbol: "VWRA", name: "World ETF", links: nil, logo_url: nil, description: nil,
        kind: "ETF", exchange_operating_mic: "XLON",
        constituents: [ { ticker: "MSFT", name: "Microsoft", weight: 100 } ]
      )
      provider = capable_provider("provider")
      provider.stubs(:class).returns(Provider::TwelveData)
      provider.stubs(:fetch_security_info).returns(provider_success_response(info))
      provider
    end
end
