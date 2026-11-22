# frozen_string_literal: true

require "test_helper"

# we-promise/sure#5440: a credit card's APR, read from what the bank reported.
#
# Every rate in a payload is a FRACTION as a string, the way
# `/v1/account-details` reports it: "0.1999" is 19.99%.
class RedbarkAccount::CreditCardDetailsProcessorTest < ActiveSupport::TestCase
  setup do
    @redbark_account = redbark_accounts(:savings_account)
    @family = @redbark_account.redbark_item.family
    @as_of = Date.new(2026, 9, 21)

    @account = @family.accounts.create!(
      name: "Card", balance: 0, currency: "AUD", accountable: CreditCard.new
    )
    @card = @account.accountable

    @redbark_account.ensure_account_provider!(@account)
    @redbark_account.reload
  end

  test "a blank APR is filled from a single untiered purchase rate" do
    detail lendingRates: [ { "rateType" => "PURCHASE", "rate" => "0.1999" } ]

    process

    assert_equal BigDecimal("19.99"), @card.reload.apr
  end

  test "agreeing purchase entries fill the APR once" do
    detail lendingRates: [
      { "rateType" => "PURCHASE", "rate" => "0.1999" },
      { "rateType" => "PURCHASE", "rate" => "0.1999", "additionalInfo" => "Standard balance transfer rate." },
      { "rateType" => "CASH_ADVANCE", "rate" => "0.2199" }
    ]

    process

    assert_equal BigDecimal("19.99"), @card.reload.apr
  end

  test "the headline lendingRate is not read for a card" do
    detail lendingRate: "0.2199"

    process

    assert_nil @card.reload.apr, "a card's APR was taken from the headline rate"
  end

  test "an APR already on the card is left alone" do
    @card.update!(apr: 12.5)
    detail lendingRates: [ { "rateType" => "PURCHASE", "rate" => "0.1999" } ]

    process

    assert_equal BigDecimal("12.5"), @card.reload.apr
  end

  test "a locked blank APR is not written" do
    @card.lock_attr!(:apr)
    detail lendingRates: [ { "rateType" => "PURCHASE", "rate" => "0.1999" } ]

    process

    assert_nil @card.reload.apr
  end

  test "several distinct purchase rates record nothing and are logged" do
    detail lendingRates: [
      { "rateType" => "PURCHASE", "rate" => "0.1999" },
      { "rateType" => "PURCHASE", "rate" => "0.2099" }
    ]

    assert_difference -> { DebugLogEntry.count }, 1 do
      process
    end

    assert_nil @card.reload.apr
  end

  test "a tiered purchase entry records nothing" do
    detail lendingRates: [ {
      "rateType" => "PURCHASE", "rate" => "0.1999",
      "tiers" => [ { "name" => "Balance tier", "minimumValue" => 0, "maximumValue" => 10_000 } ]
    } ]

    process

    assert_nil @card.reload.apr, "a rate that applies to one balance band was recorded as the card's APR"
  end

  test "a rate is rounded half-up to two places" do
    detail lendingRates: [ { "rateType" => "PURCHASE", "rate" => "0.19995" } ]

    process

    assert_equal BigDecimal("20.00"), @card.reload.apr
  end

  test "a snapshot from an earlier sync is not acted on" do
    detail lendingRates: [ { "rateType" => "PURCHASE", "rate" => "0.1999" } ],
           fetched_at: (@as_of - 3).in_time_zone

    process

    assert_nil @card.reload.apr, "a stale snapshot was recorded as though the bank had just reported it"
  end

  test "no payload writes nothing and does not raise" do
    @redbark_account.update!(raw_account_details_payload: nil)

    assert_nothing_raised { process }
    assert_nil @card.reload.apr
  end

  test "a malformed lendingRates shape writes nothing, does not raise, and is logged" do
    detail lendingRates: "not-an-array"

    assert_difference -> { DebugLogEntry.count }, 1 do
      assert_nothing_raised { process }
    end

    assert_nil @card.reload.apr
  end

  test "a filled APR records its provenance as redbark" do
    detail lendingRates: [ { "rateType" => "PURCHASE", "rate" => "0.1999" } ]

    process

    enrichment = DataEnrichment.find_by(enrichable: @card, attribute_name: "apr")
    assert_not_nil enrichment, "no provenance was recorded for the filled APR"
    assert_equal "redbark", enrichment.source
  end

  test "the annual fee is not filled from the product's fee ceiling" do
    detail(
      lendingRates: [ { "rateType" => "PURCHASE", "rate" => "0.1999" } ],
      fees: [ { "name" => "Annual fee", "amount" => "190.00", "additionalInfo" => "up to $190" } ]
    )

    process

    assert_nil @card.reload.annual_fee
  end

  test "a loan account is not treated as a credit card" do
    loan_account = @family.accounts.create!(
      name: "Mortgage", balance: 400_000, currency: "AUD",
      accountable: Loan.new(rate_type: "variable", interest_rate: 6.25)
    )
    @redbark_account.ensure_account_provider!(loan_account)
    @redbark_account.reload
    detail lendingRates: [ { "rateType" => "PURCHASE", "rate" => "0.1999" } ]

    assert_nothing_raised { process }
    assert_equal 6.25, loan_account.reload.accountable.interest_rate.to_f
  end

  private
    # Stamped as fetched on the sync's own date, which is what the importer
    # does on a successful refresh. `fetched_at:` lets a test make the snapshot
    # stale on purpose.
    def detail(fetched_at: @as_of.in_time_zone, **payload)
      @redbark_account.update!(
        raw_account_details_payload: { "accountId" => @redbark_account.redbark_account_id }.merge(
          payload.transform_keys(&:to_s)
        ),
        account_details_fetched_at: fetched_at
      )
    end

    def process
      RedbarkAccount::CreditCardDetailsProcessor.new(@redbark_account, as_of: @as_of).process
    end
end
