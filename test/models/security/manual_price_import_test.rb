require "test_helper"
require "ostruct"

class Security::ManualPriceImportTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @account = accounts(:investment)
    @security = Security.create!(ticker: "MYFUND#{SecureRandom.hex(3).upcase}", name: "My Fund", offline: true)
    @account.holdings.create!(security: @security, date: 3.days.ago.to_date, qty: 10, price: 20, amount: 200, currency: "AUD")
    @accounts = Account.where(id: @account.id)
  end

  test "creates closes in the security's currency and reports what it wrote" do
    result = import([ row(2.days.ago, "21.5"), row(1.day.ago, "22.25") ])

    assert_equal "AUD", result.currency
    assert_equal 2, result.created
    assert_equal 0, result.updated
    assert_equal 2.days.ago.to_date, result.start_date
    assert_equal 1.day.ago.to_date, result.end_date
    assert_equal [ BigDecimal("21.5"), BigDecimal("22.25") ], @security.prices.order(:date).pluck(:price)
  end

  test "a resubmitted date replaces the earlier close and clears provisional" do
    existing = @security.prices.create!(date: 1.day.ago.to_date, price: 20, currency: "AUD", provisional: true)

    result = import([ row(1.day.ago, "23") ])

    assert_equal [ 0, 1 ], [ result.created, result.updated ]
    existing.reload
    assert_equal BigDecimal("23"), existing.price
    assert_not existing.provisional
  end

  test "one bad row leaves every row in the batch unwritten" do
    @security.prices.create!(date: 5.days.ago.to_date, price: 19, currency: "AUD")

    error = assert_raises(Security::ManualPriceImport::Invalid) do
      import([ row(2.days.ago, "21"), row(5.days.ago, "18"), row(1.day.ago, "-1") ])
    end

    assert_equal [ { index: 2, message: "price must be greater than 0" } ], error.errors
    assert_equal [ BigDecimal("19") ], @security.prices.pluck(:price)
  end

  test "rejects each malformed row by its index" do
    error = assert_raises(Security::ManualPriceImport::Invalid) do
      import([
        row(1.day.ago, "0"),
        row(1.day.ago.to_date, "1.23456"),
        row(Date.current + 1, "5"),
        { "date" => "06/11/2026", "price" => "5", "currency" => "AUD" },
        row(2.days.ago, "abc"),
        row(3.days.ago, "5", currency: "ZZZ"),
        "not an object",
        row(4.days.ago, "5"),
        row(4.days.ago, "6")
      ])
    end

    assert_equal [
      { index: 0, message: "price must be greater than 0" },
      { index: 1, message: "price must have at most 4 decimal places" },
      { index: 2, message: "date must not be in the future" },
      { index: 3, message: "date must be an ISO 8601 date" },
      { index: 4, message: "price must be a number" },
      { index: 5, message: "currency must be an ISO 4217 code" },
      { index: 6, message: "row must be an object with date, price and currency" },
      { index: 8, message: "date appears more than once in this batch" }
    ], error.errors
  end

  test "a currency other than the security's own is rejected" do
    @security.prices.create!(date: 5.days.ago.to_date, price: 19, currency: "AUD")

    error = assert_raises(Security::ManualPriceImport::Invalid) { import([ row(1.day.ago, "20", currency: "USD") ]) }

    assert_equal [ { index: 0, message: "currency must be AUD, the currency of this security's prices" } ], error.errors
  end

  test "with no prices yet, the currency comes from the caller's trades before holdings" do
    @account.entries.create!(
      date: 3.days.ago.to_date, name: "Buy", amount: 100, currency: "NZD",
      entryable: Trade.new(security: @security, qty: 5, price: 20, currency: "NZD")
    )

    assert_equal "NZD", import([ row(1.day.ago, "20", currency: "NZD") ]).currency
  end

  test "trades in more than one currency leave the currency undecidable" do
    %w[NZD USD].each do |currency|
      @account.entries.create!(
        date: 3.days.ago.to_date, name: "Buy", amount: 100, currency: currency,
        entryable: Trade.new(security: @security, qty: 5, price: 20, currency: currency)
      )
    end

    error = assert_raises(Security::ManualPriceImport::Invalid) { import([ row(1.day.ago, "20", currency: "NZD") ]) }

    assert_equal [ { index: nil, message: "this security's trades are in more than one currency (NZD, USD); none can be chosen for its prices" } ], error.errors
  end

  test "a security priced in several currencies accepts only those" do
    @security.prices.create!(date: 5.days.ago.to_date, price: 19, currency: "AUD")
    @security.prices.create!(date: 5.days.ago.to_date, price: 12, currency: "USD")

    assert_equal "USD", import([ row(1.day.ago, "13", currency: "USD") ]).currency
    error = assert_raises(Security::ManualPriceImport::Invalid) { import([ row(1.day.ago, "13", currency: "EUR") ]) }
    assert_equal "currency must be AUD or USD, the currencies of this security's prices", error.errors.first[:message]
  end

  test "one batch carries one currency" do
    @security.prices.create!(date: 5.days.ago.to_date, price: 19, currency: "AUD")
    @security.prices.create!(date: 5.days.ago.to_date, price: 12, currency: "USD")

    error = assert_raises(Security::ManualPriceImport::Invalid) do
      import([ row(2.days.ago, "13", currency: "USD"), row(1.day.ago, "20", currency: "AUD") ])
    end

    assert_equal [ { index: 1, message: "every row in one request must use the same currency" } ], error.errors
  end

  test "an offline security a provider tracks is refused" do
    [
      { offline_reason: "health_check_failed" },
      { offline_reason: "provider_disabled" },
      { offline_reason: "resolution_pending" },
      { price_provider: Security.valid_price_providers.first }
    ].each do |attrs|
      @security.update_columns({ offline_reason: nil, price_provider: nil }.merge(attrs))

      error = assert_raises(Security::ManualPriceImport::Invalid, attrs.inspect) { import([ row(1.day.ago, "20") ]) }

      assert_equal [ { index: nil, message: "prices can only be imported for a security no provider tracks" } ], error.errors
    end
    assert_empty @security.prices
  end

  test "an online security is refused" do
    @security.update!(offline: false)

    error = assert_raises(Security::ManualPriceImport::Invalid) { import([ row(1.day.ago, "20") ]) }

    assert_equal [ { index: nil, message: "prices can only be imported for a security no provider tracks" } ], error.errors
    assert_empty @security.prices
  end

  test "a cash position's security is refused although it is offline" do
    cash = Security.cash_for(@account)
    assert cash.offline?

    error = assert_raises(Security::ManualPriceImport::Invalid) do
      cash.import_manual_prices!([ row(1.day.ago, "1000", currency: "USD") ], accounts: @accounts)
    end

    assert_equal [ { index: nil, message: "prices cannot be imported for a cash position" } ], error.errors
    assert_empty cash.prices
  end

  test "holdings in more than one currency leave the currency undecidable" do
    other = @account.family.accounts.create!(name: "USD broker", owner: @account.owner, accountable: Investment.new, balance: 1, currency: "USD")
    other.holdings.create!(security: @security, date: 3.days.ago.to_date, qty: 1, price: 20, amount: 20, currency: "USD")

    error = assert_raises(Security::ManualPriceImport::Invalid) do
      @security.import_manual_prices!([ row(1.day.ago, "20") ], accounts: Account.where(id: [ @account.id, other.id ]))
    end

    assert_equal [ { index: nil, message: "this security's holdings are in more than one currency (AUD, USD); none can be chosen for its prices" } ], error.errors
  end

  test "a trade with no currency does not count as a second currency" do
    entries = 2.times.map do |i|
      @account.entries.create!(
        date: (3 + i).days.ago.to_date, name: "Buy", amount: 100, currency: "AUD",
        entryable: Trade.new(security: @security, qty: 5, price: 20, currency: "AUD")
      )
    end
    entries.last.entryable.update_column(:currency, nil)

    assert_equal "AUD", import([ row(1.day.ago, "20") ]).currency
  end

  test "only calendar dates are accepted" do
    error = assert_raises(Security::ManualPriceImport::Invalid) do
      import([ row(1.day.ago, "5").merge("date" => "2026-001"), row(1.day.ago, "5").merge("date" => "20260101"),
               row(1.day.ago, "5").merge("date" => "2026-W01-1") ])
    end

    assert_equal [ 0, 1, 2 ], error.errors.map { |e| e[:index] }
    assert error.errors.all? { |e| e[:message] == "date must be an ISO 8601 date" }
  end

  test "an empty batch and one over the limit are refused" do
    assert_raises(Security::ManualPriceImport::Invalid) { import([]) }

    too_many = (1..(Security::ManualPriceImport::MAX_ROWS + 1)).map { |i| row(Date.current - i, "1") }
    error = assert_raises(Security::ManualPriceImport::Invalid) { import(too_many) }
    assert_equal "a request can carry at most #{Security::ManualPriceImport::MAX_ROWS} prices", error.errors.first[:message]
  end

  test "an imported close is what the holding is valued at, not the trade price" do
    date = 1.day.ago.to_date
    @account.entries.create!(
      date: date, name: "Buy", amount: 200, currency: "USD",
      entryable: Trade.new(security: @security, qty: 10, price: 20, currency: "USD")
    )
    Holding.where(security: @security).delete_all

    before = Holding::PortfolioCache.new(@account).get_price(@security.id, date)
    import([ row(date, "31", currency: "USD") ])
    after = Holding::PortfolioCache.new(@account).get_price(@security.id, date)

    assert_equal BigDecimal("20"), before.price
    assert_equal BigDecimal("31"), after.price
  end

  test "a provider import that runs later keeps the imported close" do
    date = 1.day.ago.to_date
    import([ row(date, "31") ])
    provider = mock
    provider.stubs(:fetch_security_prices).returns(provider_success_response([
      OpenStruct.new(security: @security, date: date, price: 99, currency: "AUD")
    ]))

    Security::Price::Importer.new(security: @security, security_provider: provider, start_date: date, end_date: date).import_provider_prices

    assert_equal BigDecimal("31"), @security.prices.find_by!(date: date, currency: "AUD").price
  end

  private
    def import(rows)
      @security.import_manual_prices!(rows, accounts: @accounts)
    end

    def row(date, price, currency: "AUD")
      { "date" => date.to_date.iso8601, "price" => price, "currency" => currency }
    end
end
