require "test_helper"

# How a fund's holdings get from the provider into `security_constituents`.
#
# The load-bearing tests are the skip gate, because it decides whether the
# provider call happens at all and so is the whole cost of the feature, and the
# capability check, because without it the gate either never closes or closes
# against the one provider that could answer.
class Security::ConstituentIngestionTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @security = securities(:aapl)
    # Metadata present from the outset. `import_provider_details` refetches for
    # METADATA reasons when a name plus a logo or website is missing, and the
    # fixture has neither -- so without this the provider is called again for a
    # reason that has nothing to do with the constituents gate, and these tests
    # would be asserting the wrong thing.
    @security.update!(name: "Apple", logo_url: "https://example.com/aapl.png")
  end

  # --------------------------------------------------------------- the gate

  test "a fund is asked once, and not asked again" do
    assert_nil @security.constituents_fetched_at

    provider = capable_provider("provider")
    provider.stubs(:class).returns(Provider::TwelveData)
    provider.expects(:fetch_security_info).once.returns(
      provider_success_response(info(constituents: [ constituent("MSFT", "Microsoft", 10) ]))
    )
    @security.stubs(:price_data_provider).returns(provider)

    @security.import_provider_details(include_constituents: true)
    assert_equal 1, @security.reload.constituents.count

    second = capable_provider("provider")
    second.expects(:fetch_security_info).never
    @security.stubs(:price_data_provider).returns(second)
    @security.import_provider_details(include_constituents: true)
  end

  # The negative, and the reason the gate is keyed on a timestamp rather than on
  # "does it have constituents". Most securities are not funds, so the provider
  # returns nothing for them -- and under a presence-keyed gate every one of them
  # would be re-asked on every sync, for ever.
  test "a security the provider has no holdings for is also not asked again" do
    import(info(constituents: nil))

    assert_empty @security.reload.constituents
    assert_not_nil @security.constituents_fetched_at, "nothing recorded that we asked"

    provider = capable_provider("provider")
    provider.expects(:fetch_security_info).never
    @security.stubs(:price_data_provider).returns(provider)

    @security.import_provider_details(include_constituents: true)
  end

  # A failed answer is not an answer. Stamping it would close the gate on a
  # fund whose holdings were never read; leaving it unstamped means the next
  # sync asks again, the same rule the classification record follows.
  test "a failed answer is not recorded, so the next sync asks again" do
    @security.constituents.create!(ticker: "MSFT", name: "Microsoft", weight: 10)
    provider = capable_provider("provider")
    provider.stubs(:class).returns(Provider::TwelveData)
    provider.expects(:fetch_security_info).twice.returns(
      provider_error_response(Provider::Error.new("fundamentals unavailable"))
    )
    @security.stubs(:price_data_provider).returns(provider)

    2.times { @security.import_provider_details(include_constituents: true) }

    assert_nil @security.reload.constituents_fetched_at
    assert_equal [ "MSFT" ], @security.constituents.pluck(:ticker), "a failed answer wiped the stored set"
  end

  # The importers walk every security on every sync, so a caller that has not
  # opted in must not inherit that cost -- the same reason
  # `include_classification:` defaults to false.
  test "a caller that has not opted in makes no provider call" do
    provider = capable_provider("provider")
    provider.expects(:fetch_security_info).never
    @security.stubs(:price_data_provider).returns(provider)

    @security.import_provider_details

    assert_empty @security.reload.constituents
    assert_nil @security.constituents_fetched_at
  end

  # A fetch made for another reason (here a missing logo) carries the holdings
  # too, but a caller that did not ask for them must not have them stored or
  # stamped: that would close the gate on its behalf.
  test "a caller that has not opted in stores nothing, even when it fetches" do
    @security.update!(logo_url: nil, website_url: nil)
    provider = capable_provider("provider")
    provider.stubs(:class).returns(Provider::TwelveData)
    provider.expects(:fetch_security_info).once.returns(
      provider_success_response(info(constituents: [ constituent("MSFT", "Microsoft", 10) ]))
    )
    @security.stubs(:price_data_provider).returns(provider)

    @security.import_provider_details

    assert_empty @security.reload.constituents
    assert_nil @security.constituents_fetched_at
  end

  test "re-importing a fund replaces its holdings rather than duplicating them" do
    import(info(constituents: [ constituent("MSFT", "Microsoft", 10), constituent("AAPL", "Apple", 5) ]))
    @security.update!(constituents_fetched_at: nil)

    import(info(constituents: [ constituent("MSFT", "Microsoft", 12) ]))

    assert_equal [ "MSFT" ], @security.reload.constituents.pluck(:ticker)
    assert_equal BigDecimal("12"), @security.constituents.sole.weight
  end

  # EODHD rounds `Assets_%`, so a position too small to round up to 0.01 comes
  # back as 0. The rows are written in one transaction, so a zero refused by a
  # validation would take the whole fund's holdings down with it.
  test "a negligible holding reported as zero does not lose the rest of the fund" do
    import(info(constituents: [
      constituent("MSFT", "Microsoft", 60.0),
      constituent("TINY", "Negligible Co", 0),
      constituent("NVDA", "Nvidia", 40.0)
    ]))

    assert_equal 3, @security.reload.constituents.count,
                 "a zero-weight holding aborted the whole import"
    assert_in_delta 0.6, @security.look_through_weights["MSFT"].to_f, 0.000001
  end

  # ----------------------------------------------------- provider capability

  # A security first synced under a provider that supplies no constituents must
  # not be stamped with an empty table, or the stamp closes the gate for ever
  # and configuring a capable provider later never fills it.
  # `price_data_provider` falls back to the first configured provider, so no
  # action on the security is needed to land in that state.
  #
  # Asserts the DELTA: empty after the incapable sync, filled after the capable
  # one.
  test "a security synced under an incapable provider is filled when a capable one arrives" do
    incapable = capable_provider("incapable", constituents: false)
    incapable.stubs(:class).returns(Provider::TwelveData)
    incapable.stubs(:fetch_security_info).returns(provider_success_response(info(constituents: nil)))
    @security.stubs(:price_data_provider).returns(incapable)
    @security.import_provider_details(include_constituents: true)

    assert_empty @security.reload.constituents, "an incapable provider stored constituents"

    capable = capable_provider("capable")
    capable.stubs(:class).returns(Provider::Eodhd)
    capable.stubs(:fetch_security_info).returns(
      provider_success_response(info(constituents: [ constituent("MSFT", "Microsoft", 10) ]))
    )
    @security.stubs(:price_data_provider).returns(capable)
    @security.import_provider_details(include_constituents: true)

    assert_equal 1, @security.reload.constituents.count,
                 "a capable provider was never asked, because the incapable one had stamped the gate shut"
  end

  # The cost half of the same rule. Gating the STAMP rather than the ask would
  # leave the flag true on every sync, and `!wants_constituents` is a separate
  # AND-term that `has_metadata` cannot short-circuit -- so every provider that
  # cannot answer would re-fetch every security, for ever.
  test "an incapable provider is not asked at all" do
    incapable = capable_provider("incapable", constituents: false, classification: false)
    incapable.stubs(:class).returns(Provider::TwelveData)
    incapable.expects(:fetch_security_info).never
    @security.stubs(:price_data_provider).returns(incapable)

    @security.import_provider_details(include_constituents: true)

    assert_nil @security.reload.constituents_fetched_at,
               "an incapable provider left a stamp, which would close the gate against a capable one"
  end

  # The second lock on the same door. `store_constituents` deletes before it
  # writes, so an incapable provider reaching it would wipe a set it was never
  # in a position to replace.
  test "an incapable provider cannot wipe a stored set" do
    import(info(constituents: [ constituent("MSFT", "Microsoft", 10) ]))
    assert_equal 1, @security.reload.constituents.count

    incapable = capable_provider("incapable", constituents: false)
    @security.stubs(:price_data_provider).returns(incapable)
    @security.send(:store_constituents, nil)

    assert_equal 1, @security.reload.constituents.count,
                 "an incapable provider emptied the table and stamped the emptiness as fact"
  end

  private
    def constituent(ticker, name, weight)
      { ticker: ticker, name: name, weight: weight }
    end

    def info(constituents:)
      Provider::SecurityConcept::SecurityInfo.new(
        symbol: "AAPL", name: nil, links: nil, logo_url: nil, description: nil,
        kind: nil, exchange_operating_mic: "XNAS", constituents: constituents
      )
    end

    def import(data)
      provider = capable_provider("provider")
      provider.stubs(:class).returns(Provider::TwelveData)
      provider.stubs(:fetch_security_info).returns(provider_success_response(data))
      @security.stubs(:price_data_provider).returns(provider)
      @security.import_provider_details(include_constituents: true)
    end
end
