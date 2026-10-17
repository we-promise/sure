require "test_helper"

class WiseActivity::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @wise_item = WiseItem.create!(
      family: @family,
      name: "Test Wise",
      token: "test_token",
      profile_id: "123",
      profile_type: :business
    )

    @jar_account = WiseAccount.create!(
      wise_item: @wise_item,
      balance_id: "10000002",
      name: "Jar",
      currency: "EUR",
      raw_payload: { "type" => "SAVINGS", "name" => "Jar" }
    )
    @jar_sure_account = Account.create!(
      family: @family,
      name: "Jar",
      accountable: Depository.new(subtype: "savings"),
      balance: 0,
      currency: "EUR"
    )
    AccountProvider.create!(account: @jar_sure_account, provider: @jar_account)

    @standard_account = WiseAccount.create!(
      wise_item: @wise_item,
      balance_id: "10000001",
      name: "Wise EUR",
      currency: "EUR",
      raw_payload: { "type" => "STANDARD", "recipient_id" => 99999001 }
    )
    @standard_sure_account = Account.create!(
      family: @family,
      name: "Wise EUR",
      accountable: Depository.new(subtype: "checking"),
      balance: 0,
      currency: "EUR"
    )
    AccountProvider.create!(account: @standard_sure_account, provider: @standard_account)
  end

  # INTERBALANCE — JAR side

  test "INTERBALANCE 'To Jar' on JAR account is income (negative)" do
    activity = build_interbalance("To <strong>Jar</strong>", amount: "1,000 EUR", resource_id: "5001")

    entry = WiseActivity::Processor.new(activity, wise_account: @jar_account).process

    assert_equal BigDecimal("-1000.0"), entry.amount
    assert_equal "wise_interbalance_5001_inflow", entry.external_id
    assert_equal I18n.t("wise_items.activities.jar_deposit"), entry.name
  end

  test "INTERBALANCE 'From Jar' on JAR account is expense (positive)" do
    activity = build_interbalance("From <strong>EUR</strong>", amount: "500 EUR", resource_id: "5002")
    # Simulates a withdrawal: title doesn't start with "To"

    entry = WiseActivity::Processor.new(activity, wise_account: @jar_account).process

    assert_equal BigDecimal("500.0"), entry.amount
    assert_equal "wise_interbalance_5002_inflow", entry.external_id
    assert_equal I18n.t("wise_items.activities.jar_withdrawal"), entry.name
  end

  # INTERBALANCE — STANDARD side

  test "INTERBALANCE 'To Jar' on STANDARD account is expense (positive outflow)" do
    activity = build_interbalance("To <strong>Jar</strong>", amount: "1,000 EUR", resource_id: "5003")

    entry = WiseActivity::Processor.new(activity, wise_account: @standard_account).process

    assert_equal BigDecimal("1000.0"), entry.amount
    assert_equal "wise_interbalance_5003_outflow", entry.external_id
  end

  # INTERBALANCE — currency conversion between STANDARD balances

  test "conversion on the source STANDARD balance is an outflow in the source currency" do
    gbp_account = create_standard_account(currency: "GBP", balance_id: "10000003")
    activity = build_interbalance("To <strong>EUR</strong>", amount: "117.50 EUR", resource_id: "8001",
                                  secondary: "100 GBP")

    entry = WiseActivity::Processor.new(activity, wise_account: gbp_account).process

    assert_equal BigDecimal("100.0"), entry.amount
    assert_equal "GBP", entry.currency
    assert_equal "wise_interbalance_8001_outflow", entry.external_id
    assert_equal I18n.t("wise_items.activities.transfer_to_jar", jar: "EUR"), entry.name
  end

  # An older build booked the leg in the target currency (primaryAmount). A
  # person's category does not freeze that figure.
  test "corrects a conversion leg an older build booked in the other currency, also after a person categorized it" do
    gbp_account = create_standard_account(currency: "GBP", balance_id: "10000003")
    old = gbp_account.current_account.entries.create!(external_id: "wise_interbalance_8003_outflow", source: "wise", amount: 117.5,
                                                      currency: "EUR", date: Date.new(2026, 5, 1), name: "To EUR",
                                                      user_modified: true, entryable: Transaction.new)
    activity = build_interbalance("To <strong>EUR</strong>", amount: "117.50 EUR", resource_id: "8003", secondary: "100 GBP")

    entry = WiseActivity::Processor.new(activity, wise_account: gbp_account).process

    assert_equal old.id, entry.id
    assert_equal [ BigDecimal("100"), "GBP" ], old.reload.values_at(:amount, :currency)
    assert old.user_modified?
  end

  test "conversion on the target STANDARD balance is an inflow in the target currency" do
    activity = build_interbalance("To <strong>EUR</strong>", amount: "1,234.56 EUR", resource_id: "8002",
                                  secondary: "900 GBP")

    entry = WiseActivity::Processor.new(activity, wise_account: @standard_account).process

    assert_equal BigDecimal("-1234.56"), entry.amount
    assert_equal "EUR", entry.currency
    assert_equal "wise_interbalance_8002_inflow", entry.external_id
    assert_equal I18n.t("wise_items.activities.transfer_from_jar", jar: "GBP"), entry.name
  end

  # Amount parsing

  test "parses comma-formatted amount" do
    activity = build_interbalance("To <strong>Jar</strong>", amount: "2,500 EUR", resource_id: "6001")

    entry = WiseActivity::Processor.new(activity, wise_account: @jar_account).process

    assert_equal BigDecimal("-2500.0"), entry.amount
  end

  test "parses HTML-wrapped positive amount" do
    activity = build_cashback(amount: "<positive>+ 3.53 EUR</positive>", resource_id: "57001")

    entry = WiseActivity::Processor.new(activity, wise_account: @jar_account).process

    assert_equal BigDecimal("-3.53"), entry.amount
  end

  test "parses plain decimal amount" do
    activity = build_asset_fee(amount: "0.83 EUR", resource_id: "18001")

    entry = WiseActivity::Processor.new(activity, wise_account: @jar_account).process

    assert_equal BigDecimal("0.83"), entry.amount
  end

  # Amount strings, in the shapes Wise returns

  test "parse_amount reads value, currency and markup" do
    assert_equal({ value: BigDecimal("1618.42"), currency: "USD", currencies: [ "USD" ], marked: nil, sign: nil },
                 WiseActivity::Processor.parse_amount("1,618.42 USD"))
    assert_equal({ value: BigDecimal("2465"), currency: "GBP", currencies: [ "GBP" ], marked: :positive, sign: 1 },
                 WiseActivity::Processor.parse_amount("<positive>+ 2,465 GBP</positive>"))
    assert_equal({ value: BigDecimal("0"), currency: "EUR", currencies: [ "EUR" ], marked: nil, sign: nil },
                 WiseActivity::Processor.parse_amount("0 EUR"))
  end

  test "parse_amount reads a split-funding list as currencies without a value" do
    assert_equal({ value: nil, currency: "GBP", currencies: %w[GBP EUR], marked: nil, sign: nil },
                 WiseActivity::Processor.parse_amount("GBP, EUR"))
    assert_equal({ value: nil, currency: "AUD", currencies: %w[AUD EUR], marked: nil, sign: nil },
                 WiseActivity::Processor.parse_amount("AUD, EUR"))
  end

  test "parse_amount tells positive from negative amounts" do
    positive = WiseActivity::Processor.parse_amount("<positive>+ 0.64 EUR</positive>")
    negative = WiseActivity::Processor.parse_amount("<negative>- 0.64 EUR</negative>")

    assert_equal [ BigDecimal("0.64"), :positive, 1 ], positive.values_at(:value, :marked, :sign)
    assert_equal [ BigDecimal("0.64"), :negative, -1 ], negative.values_at(:value, :marked, :sign)
    # A leading sign without markup counts as well.
    assert_equal :positive, WiseActivity::Processor.parse_amount("+ 1.12 EUR")[:marked]
    assert_equal :negative, WiseActivity::Processor.parse_amount("-3 EUR")[:marked]
  end

  test "parse_amount of a missing amount is empty" do
    empty = { value: nil, currency: nil, currencies: [], marked: nil, sign: nil }

    assert_equal empty, WiseActivity::Processor.parse_amount("")
    assert_equal empty, WiseActivity::Processor.parse_amount(nil)
  end

  test "parse_money needs a digit, so a split-funding list has no amount" do
    # The old pattern read the lone comma in "GBP, EUR" as 0 GBP.
    assert_equal [ nil, "GBP" ], WiseActivity::Processor.parse_money("GBP, EUR")
    assert_equal [ nil, "AUD" ], WiseActivity::Processor.parse_money("AUD, EUR")
    assert_equal [ BigDecimal("1618.42"), "USD" ], WiseActivity::Processor.parse_money("1,618.42 USD")
    assert_equal [ BigDecimal("2465"), "GBP" ], WiseActivity::Processor.parse_money("<positive>+ 2,465 GBP</positive>")
    assert_equal [ BigDecimal("0"), "EUR" ], WiseActivity::Processor.parse_money("0 EUR")
  end

  # Direction of single-leg activities

  test "a positive-marked activity is a credit whatever its type" do
    assert_equal :credit, direction_of("CARD_PAYMENT", "<positive>+ 0.64 EUR</positive>")
    assert_equal :credit, direction_of("TRANSFER", "<positive>+ 2,465 GBP</positive>")
    assert_equal :credit, direction_of("BALANCE_DEPOSIT", "<positive>+ 715 GBP</positive>")
    assert_equal :credit, direction_of("CARD_PAYMENT", "7.40 EUR", "<positive>+ 6.42 GBP</positive>")
  end

  test "an unmarked activity is a debit unless its type only ever pays in" do
    assert_equal :debit, direction_of("CARD_PAYMENT", "7.40 EUR", "6.42 GBP")
    assert_equal :debit, direction_of("TRANSFER", "1,618.42 USD", "1,620.79 USD")
    assert_equal :debit, direction_of("CASH_WITHDRAWAL", "150 CHF", "GBP, CHF")
    assert_equal :debit, direction_of("DIRECT_DEBIT_TRANSACTION", "64.20 CAD")
    assert_equal :debit, direction_of("BALANCE_ASSET_FEE", "0.06 EUR")

    %w[REWARD CARD_CASHBACK BALANCE_INTEREST BALANCE_CASHBACK].each do |type|
      assert_equal :credit, direction_of(type, "1.12 EUR"), type
      assert_equal :debit, direction_of(type, "<negative>- 1.12 EUR</negative>"), type
    end
  end

  test "a conversion between two balances has no single direction" do
    assert_nil direction_of("INTERBALANCE", "117.50 EUR", "100 GBP")
    assert_nil direction_of("AUTO_CONVERSION", "117.50 EUR", "100 GBP")
  end

  # Amount a single-leg activity moved on its balance

  test "a debit books what left the paying balance" do
    # Card payment auto-converted from GBP: the merchant got 7.40 EUR.
    assert_equal [ BigDecimal("6.42"), "GBP" ], booked("CARD_PAYMENT", "7.40 EUR", "6.42 GBP")
    assert_equal [ BigDecimal("3.29"), "EUR" ], booked("CARD_PAYMENT", "2.84 GBP", "3.29 EUR")
    # Payouts: the secondary is the gross debit, fee included.
    assert_equal [ BigDecimal("1620.79"), "USD" ], booked("TRANSFER", "1,618.42 USD", "1,620.79 USD")
    assert_equal [ BigDecimal("212.86"), "GBP" ], booked("TRANSFER", "41,500 JPY", "212.86 GBP")
    # Same currency and no fee: Wise leaves the secondary empty.
    assert_equal [ BigDecimal("37.65"), "EUR" ], booked("CARD_PAYMENT", "37.65 EUR", "")
    assert_equal [ BigDecimal("0"), "CHF" ], booked("CARD_CHECK", "0 CHF", "")
  end

  test "a credit books the primary amount, which is what Wise credited" do
    refund = build_activity("CARD_PAYMENT", "<positive>+ 0.64 EUR</positive>", "")

    assert_equal({ value: BigDecimal("0.64"), currency: "EUR", direction: :credit, split: false, currencies: [ "EUR" ] },
                 WiseActivity::Processor.balance_amount(refund))
    assert_equal [ BigDecimal("6.42"), "GBP" ], booked("CARD_PAYMENT", "<positive>+ 6.42 GBP</positive>", "7.40 EUR")
    assert_equal [ BigDecimal("2465"), "GBP" ], booked("TRANSFER", "<positive>+ 2,465 GBP</positive>", "")
  end

  test "a debit funded from several balances is split without per-balance amounts" do
    atm = build_activity("CASH_WITHDRAWAL", "150 CHF", "GBP, CHF")
    card = build_activity("CARD_PAYMENT", "17.60 CHF", "AUD, CHF")

    assert WiseActivity::Processor.split?(atm)
    assert_equal({ value: BigDecimal("150"), currency: "CHF", direction: :debit, split: true, currencies: %w[GBP CHF] },
                 WiseActivity::Processor.balance_amount(atm))
    assert WiseActivity::Processor.split?(card)
    assert_equal %w[AUD CHF], WiseActivity::Processor.balance_amount(card)[:currencies]
  end

  test "only debits are split" do
    refund = build_activity("CARD_PAYMENT", "<positive>+ 26.80 EUR</positive>", "GBP, EUR")
    single = build_activity("CARD_PAYMENT", "7.40 EUR", "6.42 GBP")

    assert_not WiseActivity::Processor.split?(refund)
    assert_equal({ value: BigDecimal("26.80"), currency: "EUR", direction: :credit, split: false, currencies: [ "EUR" ] },
                 WiseActivity::Processor.balance_amount(refund))
    assert_not WiseActivity::Processor.split?(single)
  end

  test "a conversion has no single balance amount" do
    conversion = build_interbalance("To <strong>EUR</strong>", amount: "117.50 EUR", resource_id: "8003", secondary: "100 GBP")

    assert_nil WiseActivity::Processor.balance_amount(conversion)
    assert_not WiseActivity::Processor.split?(conversion)
  end

  test "books a single-leg activity with its markup's sign and the paying balance's amount" do
    gbp_account = create_standard_account(currency: "GBP", balance_id: "10000003")
    refund = build_activity("CARD_PAYMENT", "<positive>+ 0.64 EUR</positive>", "", id: "card_refund_1")
    payment = build_activity("CARD_PAYMENT", "7.40 EUR", "6.42 GBP", id: "card_payment_1")

    refund_entry = WiseActivity::Processor.new(refund, wise_account: @standard_account).process
    payment_entry = WiseActivity::Processor.new(payment, wise_account: gbp_account).process

    assert_equal [ BigDecimal("-0.64"), "EUR" ], [ refund_entry.amount, refund_entry.currency ]
    assert_equal [ BigDecimal("6.42"), "GBP" ], [ payment_entry.amount, payment_entry.currency ]
  end

  test "a negative-marked cashback is booked as an expense" do
    activity = build_cashback(amount: "<negative>- 0.10 EUR</negative>", resource_id: "57005")

    entry = WiseActivity::Processor.new(activity, wise_account: @jar_account).process

    assert_equal BigDecimal("0.10"), entry.amount
  end

  # Status: only a completed activity moved money

  test "books an activity only once Wise has completed it" do
    gbp_account = create_standard_account(currency: "GBP", balance_id: "10000003")

    %w[IN_PROGRESS UPCOMING REQUIRES_ATTENTION CANCELLED].each do |status|
      payment = build_activity("CARD_PAYMENT", "7.40 EUR", "6.42 GBP", id: "card_#{status.downcase}").merge("status" => status)
      processor = WiseActivity::Processor.new(payment, wise_account: gbp_account)

      assert_equal [], processor.expected_external_ids, status
      assert_equal :skipped, processor.process, status
    end
    assert_equal 0, gbp_account.current_account.entries.count

    completed = WiseActivity::Processor.new(build_activity("CARD_PAYMENT", "7.40 EUR", "6.42 GBP", id: "card_done"),
                                            wise_account: gbp_account)
    assert_equal [ "wise_activity_card_done" ], completed.expected_external_ids
    assert_equal "wise_activity_card_done", completed.process.external_id
  end

  # A cancelled activity is not booked.
  test "a cancelled conversion books neither leg" do
    activity = build_interbalance("To <strong>EUR</strong>", amount: "22.91 EUR", resource_id: "778", secondary: "20 GBP")
                 .merge("status" => "CANCELLED")
    processor = WiseActivity::Processor.new(activity, wise_account: @standard_account)

    assert_equal [], processor.expected_external_ids
    assert_equal :skipped, processor.process
    assert_nil Entry.find_by(external_id: "wise_interbalance_778_inflow")
  end

  # Split funding: Wise names the balances ("GBP, EUR"), not what each paid

  test "books the balance replay's part of a split payment on each balance that paid" do
    gbp_account = create_standard_account(currency: "GBP", balance_id: "10000003")
    payment = build_activity("CARD_PAYMENT", "26.80 EUR", "GBP, EUR", id: "split_card")
                .merge("wise_split_parts" => { "EUR" => "12.35", "GBP" => "12.42" }, "wise_split_estimated" => [ "GBP" ])

    eur_entry = WiseActivity::Processor.new(payment, wise_account: @standard_account).process
    gbp_entry = WiseActivity::Processor.new(payment, wise_account: gbp_account).process

    assert_equal [ "wise_activity_split_card", BigDecimal("12.35"), "EUR" ], [ eur_entry.external_id, eur_entry.amount, eur_entry.currency ]
    assert_equal [ "wise_activity_split_card", BigDecimal("12.42"), "GBP" ], [ gbp_entry.external_id, gbp_entry.amount, gbp_entry.currency ]
    assert_equal({ "split_part" => true }, split_flags(eur_entry))
    assert_equal({ "split_part" => true, "split_estimated" => true }, split_flags(gbp_entry))
  end

  # Documented limitation: without a replay (no full history) Sure cannot tell
  # the parts, so the merchant-currency balance books the whole amount.
  test "without replayed parts a split payment books its full amount on the merchant-currency balance only" do
    gbp_account = create_standard_account(currency: "GBP", balance_id: "10000003")
    atm = build_activity("CASH_WITHDRAWAL", "150 EUR", "GBP, EUR", id: "split_atm")
    eur_processor = WiseActivity::Processor.new(atm, wise_account: @standard_account)
    gbp_processor = WiseActivity::Processor.new(atm, wise_account: gbp_account)

    assert_equal [ "wise_activity_split_atm" ], eur_processor.expected_external_ids
    assert_equal [], gbp_processor.expected_external_ids

    entry = eur_processor.process
    assert_equal [ BigDecimal("150"), "EUR" ], [ entry.amount, entry.currency ]
    assert_equal({ "split_unresolved" => true }, split_flags(entry))
    assert_equal :skipped, gbp_processor.process
    assert_equal 0, gbp_account.current_account.entries.count
  end

  # Wise drew on GBP and EUR for a payment in a currency the profile does not
  # hold, so no balance the payment lists is in the merchant's currency: the
  # first one books it in full rather than none of them.
  test "without replayed parts a split payment in another currency books in full on the first balance it lists" do
    gbp_account = create_standard_account(currency: "GBP", balance_id: "10000003")
    payment = build_activity("CARD_PAYMENT", "100 USD", "GBP, EUR", id: "split_usd")
    gbp_processor = WiseActivity::Processor.new(payment, wise_account: gbp_account)
    eur_processor = WiseActivity::Processor.new(payment, wise_account: @standard_account)

    assert_equal [ [ "wise_activity_split_usd" ], [] ], [ gbp_processor.expected_external_ids, eur_processor.expected_external_ids ]
    entry = gbp_processor.process
    assert_equal [ BigDecimal("100"), "USD" ], [ entry.amount, entry.currency ]
    assert_equal({ "split_unresolved" => true }, split_flags(entry))
    assert_equal :skipped, eur_processor.process

    parts = WiseActivity::Processor.new(payment.merge("wise_split_parts" => { "GBP" => "40.10", "EUR" => "45.60" }), wise_account: gbp_account).process
    assert_equal [ entry.id, BigDecimal("40.10"), "GBP" ], [ parts.id, parts.amount, parts.currency ]
  end

  # A person's share of a split entry is not a copy of a new Wise row of the
  # same amount and day, so it is never claimed for it.
  test "books a card payment of a split part's amount and day as its own entry" do
    parent = @standard_sure_account.entries.create!(date: Date.new(2025, 9, 17), amount: 37.5, currency: "EUR", name: "Market",
                                                    entryable: Transaction.new)
    parent.split!([ { name: "Groceries", amount: 25, category_id: nil }, { name: "Household", amount: 12.5, category_id: nil } ])
    household = parent.child_entries.find_by!(name: "Household")

    entry = WiseActivity::Processor.new(build_activity("CARD_PAYMENT", "12.50 EUR", id: "card_b"), wise_account: @standard_account).process

    assert_not_equal household.id, entry.id
    assert_equal [ nil, nil, "Household" ], household.reload.values_at(:external_id, :source, :name)
  end

  # The extra.wise namespace is replaced on every import, not merged, so the
  # flag a split payment had before the balance replay found its parts does
  # not stay on the entry.
  test "re-importing a split payment drops the flag its earlier booking had" do
    atm = build_activity("CASH_WITHDRAWAL", "150 EUR", "GBP, EUR", id: "split_atm")
    WiseActivity::Processor.new(atm, wise_account: @standard_account).process

    entry = WiseActivity::Processor.new(atm.merge("wise_split_parts" => { "EUR" => "145.18", "GBP" => "4.50" }),
                                        wise_account: @standard_account).process

    assert_equal [ BigDecimal("145.18"), { "split_part" => true } ], [ entry.amount, split_flags(entry.reload) ]
  end

  test "a split part of zero books nothing on that balance" do
    gbp_account = create_standard_account(currency: "GBP", balance_id: "10000003")
    atm = build_activity("CASH_WITHDRAWAL", "150 EUR", "GBP, EUR", id: "split_atm")
            .merge("wise_split_parts" => { "EUR" => "150.00", "GBP" => "0.00" })
    processor = WiseActivity::Processor.new(atm, wise_account: gbp_account)

    assert_equal [], processor.expected_external_ids
    assert_equal :skipped, processor.process
  end

  # AUTO_CONVERSION moves money between two balances like a conversion

  test "an auto-conversion books both legs the way a conversion does" do
    gbp_account = create_standard_account(currency: "GBP", balance_id: "10000003")
    conversion = build_interbalance("To <strong>EUR</strong>", amount: "117.50 EUR", resource_id: "9001", secondary: "100 GBP")
                   .merge("type" => "AUTO_CONVERSION", "id" => "auto_conversion_9001")

    outflow = WiseActivity::Processor.new(conversion, wise_account: gbp_account).process
    inflow = WiseActivity::Processor.new(conversion, wise_account: @standard_account).process

    assert_equal [ "wise_interbalance_9001_outflow", BigDecimal("100"), "GBP" ], [ outflow.external_id, outflow.amount, outflow.currency ]
    assert_equal [ "wise_interbalance_9001_inflow", BigDecimal("-117.50"), "EUR" ], [ inflow.external_id, inflow.amount, inflow.currency ]
    assert_equal I18n.t("wise_items.activities.transfer_to_jar", jar: "EUR"), outflow.name
    assert_equal I18n.t("wise_items.activities.transfer_from_jar", jar: "GBP"), inflow.name
  end

  # Names and metadata

  test "names a single-leg activity after its title and keeps Wise's amounts in extra" do
    gbp_account = create_standard_account(currency: "GBP", balance_id: "10000003")
    payment = build_activity("CARD_PAYMENT", "7.40 EUR", "6.42 GBP", id: "named_card")
                .merge("title" => "<strong>Tom &amp; Jerry</strong>", "description" => "Spent")

    entry = WiseActivity::Processor.new(payment, wise_account: gbp_account).process

    assert_equal "Tom & Jerry", entry.name
    assert_equal({ "activity_id" => "named_card", "activity_type" => "CARD_PAYMENT", "resource_type" => "CARD_TRANSACTION",
                   "resource_id" => "3000001", "description" => "Spent", "primary_amount" => "7.40 EUR",
                   "secondary_amount" => "6.42 GBP" }, entry.entryable.extra["wise"])
  end

  test "names balance interest like cashback" do
    interest = build_activity("BALANCE_INTEREST", "0.42 EUR", id: "interest_1")

    entry = WiseActivity::Processor.new(interest, wise_account: @standard_account).process

    assert_equal [ BigDecimal("-0.42"), I18n.t("wise_items.activities.interest") ], [ entry.amount, entry.name ]
  end

  # Dates

  test "dates an activity in the family time zone, like transfers and statements" do
    @family.update!(timezone: "Europe/Dublin")
    activity = build_interbalance("To <strong>EUR</strong>", amount: "15 EUR", resource_id: "8004", secondary: "13 GBP")
                 .merge("createdOn" => "2026-08-11T23:52:27.164Z")

    entry = WiseActivity::Processor.new(activity, wise_account: @standard_account).process

    # 23:52 UTC on 11 August is 00:52 on 12 August in Dublin (IST).
    assert_equal Date.new(2026, 8, 12), entry.date
  end

  test "created_at is the UTC instant of createdOn" do
    assert_equal Time.utc(2026, 9, 16, 22, 41, 38.553r),
                 WiseActivity::Processor.created_at({ "createdOn" => "2026-09-16T22:41:38.553Z" })
    assert_nil WiseActivity::Processor.created_at({ "createdOn" => "" })
  end

  # BALANCE_CASHBACK (interest)

  test "BALANCE_CASHBACK is imported as income (negative)" do
    activity = build_cashback(amount: "<positive>+ 1.12 EUR</positive>", resource_id: "57002")

    entry = WiseActivity::Processor.new(activity, wise_account: @jar_account).process

    assert_equal BigDecimal("-1.12"), entry.amount
    assert_equal I18n.t("wise_items.activities.interest"), entry.name
    assert_equal "wise_activity_#{activity["id"]}", entry.external_id
  end

  # BALANCE_ASSET_FEE

  test "BALANCE_ASSET_FEE is imported as expense (positive)" do
    activity = build_asset_fee(amount: "0.06 EUR", resource_id: "18002")

    entry = WiseActivity::Processor.new(activity, wise_account: @jar_account).process

    assert_equal BigDecimal("0.06"), entry.amount
    assert_equal I18n.t("wise_items.activities.asset_fee"), entry.name
    assert_equal "wise_activity_#{activity["id"]}", entry.external_id
  end

  # Deduplication

  test "re-processing same activity returns existing entry" do
    activity = build_cashback(amount: "<positive>+ 0.09 EUR</positive>", resource_id: "57003")

    entry1 = WiseActivity::Processor.new(activity, wise_account: @jar_account).process
    entry2 = WiseActivity::Processor.new(activity, wise_account: @jar_account).process

    assert_equal entry1.id, entry2.id
    assert_equal 1, @jar_sure_account.entries.where(source: "wise").count
  end

  # Skips without linked account

  test "returns skipped when JAR has no linked Sure account" do
    unlinked = WiseAccount.create!(
      wise_item: @wise_item,
      balance_id: "10000099",
      name: "Unlinked Jar",
      currency: "EUR",
      raw_payload: { "type" => "SAVINGS", "name" => "Jar" }
    )

    result = WiseActivity::Processor.new(
      build_cashback(amount: "0.10 EUR", resource_id: "1"),
      wise_account: unlinked
    ).process

    assert_equal :skipped, result
  end

  # Extra metadata

  test "stores wise activity metadata in entry extra" do
    activity = build_cashback(amount: "1.00 EUR", resource_id: "57004")

    entry = WiseActivity::Processor.new(activity, wise_account: @jar_account).process

    extra = entry.entryable.extra
    assert_equal "BALANCE_CASHBACK", extra.dig("wise", "activity_type")
    assert_equal "BALANCE_CASHBACK", extra.dig("wise", "resource_type")
    assert_equal "57004", extra.dig("wise", "resource_id")
  end

  private

    def build_interbalance(title, amount:, resource_id:, secondary: nil)
      {
        "id" => "interbalance_activity_#{resource_id}",
        "type" => "INTERBALANCE",
        "resource" => { "type" => "BALANCE_TRANSACTION", "id" => resource_id },
        "title" => title,
        "primaryAmount" => amount,
        "secondaryAmount" => secondary,
        "status" => "COMPLETED",
        "createdOn" => "2026-05-01T06:12:11.597Z"
      }.compact
    end

    def create_standard_account(currency:, balance_id:)
      wise_account = WiseAccount.create!(
        wise_item: @wise_item,
        balance_id: balance_id,
        name: "Wise #{currency}",
        currency: currency,
        raw_payload: { "type" => "STANDARD" }
      )
      AccountProvider.create!(
        account: Account.create!(
          family: @family,
          name: "Wise #{currency}",
          accountable: Depository.new(subtype: "checking"),
          balance: 0,
          currency: currency
        ),
        provider: wise_account
      )
      wise_account
    end

    def build_activity(type, primary, secondary = nil, id: "#{type.downcase}_activity")
      {
        "id" => id,
        "type" => type,
        "resource" => { "type" => "CARD_TRANSACTION", "id" => "3000001" },
        "title" => "<strong>Merchant</strong>",
        "primaryAmount" => primary,
        "secondaryAmount" => secondary,
        "status" => "COMPLETED",
        "createdOn" => "2025-09-17T15:33:48.972Z"
      }.compact
    end

    def direction_of(type, primary, secondary = nil)
      WiseActivity::Processor.direction(build_activity(type, primary, secondary))
    end

    def booked(type, primary, secondary = nil)
      WiseActivity::Processor.balance_amount(build_activity(type, primary, secondary)).values_at(:value, :currency)
    end

    def split_flags(entry)
      entry.entryable.extra["wise"].slice("split_part", "split_estimated", "split_unresolved")
    end

    def build_cashback(amount:, resource_id:)
      {
        "id" => "cashback_activity_#{resource_id}",
        "type" => "BALANCE_CASHBACK",
        "resource" => { "type" => "BALANCE_CASHBACK", "id" => resource_id },
        "title" => "<strong>Cashback</strong>",
        "primaryAmount" => amount,
        "status" => "COMPLETED",
        "createdOn" => "2026-06-03T07:26:34.500Z"
      }
    end

    def build_asset_fee(amount:, resource_id:)
      {
        "id" => "fee_activity_#{resource_id}",
        "type" => "BALANCE_ASSET_FEE",
        "resource" => { "type" => "ACCRUAL_CHARGE", "id" => resource_id },
        "title" => "<strong>Wise Assets Europe fee</strong>",
        "primaryAmount" => amount,
        "status" => "COMPLETED",
        "createdOn" => "2026-06-02T18:11:07.593Z"
      }
    end
end
