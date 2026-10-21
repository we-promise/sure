require "test_helper"

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
