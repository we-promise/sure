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
