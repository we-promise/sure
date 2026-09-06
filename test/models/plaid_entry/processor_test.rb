require "test_helper"

class PlaidEntry::ProcessorTest < ActiveSupport::TestCase
  setup do
    @plaid_account = plaid_accounts(:one)
    @category_matcher = mock("PlaidAccount::Transactions::CategoryMatcher")
  end

  def prefer_original_description!
    @plaid_account.plaid_item.family.update!(plaid_prefer_original_description: true)
  end

  test "creates new entry transaction preferring original description" do
    prefer_original_description!

    plaid_transaction = {
      "transaction_id" => "123",
      "merchant_name" => "Amazon",
      "original_description" => "AMZN Mktp US*AB12CD SEATTLE WA",
      "amount" => 100,
      "date" => Date.current,
      "iso_currency_code" => "USD",
      "payment_channel" => "online",
      "transaction_code" => nil,
      "payment_meta" => {
        "payee" => "Amazon",
        "ppd_id" => nil,
        "reference_number" => "REF-1"
      },
      "counterparties" => [
        { "name" => "Amazon", "type" => "merchant", "confidence_level" => "VERY_HIGH", "entity_id" => "ent_1" }
      ],
      "personal_finance_category" => {
        "detailed" => "Food"
      },
      "merchant_entity_id" => "123"
    }

    @category_matcher.expects(:match).with("Food").returns(categories(:food_and_drink))

    processor = PlaidEntry::Processor.new(
      plaid_transaction,
      plaid_account: @plaid_account,
      category_matcher: @category_matcher
    )

    assert_difference [ "Entry.count", "Transaction.count", "ProviderMerchant.count" ], 1 do
      processor.process
    end

    entry = Entry.order(created_at: :desc).first

    assert_equal 100, entry.amount
    assert_equal "USD", entry.currency
    assert_equal Date.current, entry.date
    assert_equal "AMZN Mktp US*AB12CD SEATTLE WA", entry.name
    assert_equal categories(:food_and_drink).id, entry.transaction.category_id

    plaid_extra = entry.transaction.extra.fetch("plaid")
    assert_equal "AMZN Mktp US*AB12CD SEATTLE WA", plaid_extra["original_description"]
    assert_equal "online", plaid_extra["payment_channel"]
    assert_equal({ "payee" => "Amazon", "reference_number" => "REF-1" }, plaid_extra["payment_meta"])
    assert_equal 1, plaid_extra["counterparties"].size
    assert_equal "Amazon", plaid_extra["counterparties"].first["name"]
    assert_nil plaid_extra["transaction_code"]

    provider_merchant = ProviderMerchant.order(created_at: :desc).first

    assert_equal "Amazon", provider_merchant.name
  end

  test "falls back to merchant name when original description is missing" do
    plaid_transaction = {
      "transaction_id" => "no-original",
      "merchant_name" => "Amazon",
      "amount" => 50,
      "date" => Date.current,
      "iso_currency_code" => "USD",
      "personal_finance_category" => {
        "detailed" => "Food"
      },
      "merchant_entity_id" => "no-original-merchant"
    }

    @category_matcher.expects(:match).with("Food").returns(categories(:food_and_drink))

    processor = PlaidEntry::Processor.new(
      plaid_transaction,
      plaid_account: @plaid_account,
      category_matcher: @category_matcher
    )

    processor.process
    entry = Entry.find_by!(external_id: "no-original", source: "plaid")
    assert_equal "Amazon", entry.name
  end

  test "prefers merchant name by default" do
    plaid_transaction = {
      "transaction_id" => "merchant-first",
      "merchant_name" => "Amazon",
      "original_description" => "AMZN Mktp US*AB12CD SEATTLE WA",
      "amount" => 75,
      "date" => Date.current,
      "iso_currency_code" => "USD",
      "personal_finance_category" => {
        "detailed" => "Food"
      },
      "merchant_entity_id" => "merchant-first-id"
    }

    @category_matcher.expects(:match).with("Food").returns(categories(:food_and_drink))

    processor = PlaidEntry::Processor.new(
      plaid_transaction,
      plaid_account: @plaid_account,
      category_matcher: @category_matcher
    )

    processor.process
    entry = Entry.find_by!(external_id: "merchant-first", source: "plaid")
    assert_equal "Amazon", entry.name
  end

  test "updates existing entry transaction" do
    prefer_original_description!

    existing_plaid_id = "existing_plaid_id"

    plaid_transaction = {
      "transaction_id" => existing_plaid_id,
      "merchant_name" => "Amazon",
      "original_description" => "AMZN Mktp US*UPDATED",
      "amount" => 200, # Changed amount will be updated
      "date" => 1.day.ago.to_date, # Changed date will be updated
      "iso_currency_code" => "USD",
      "payment_channel" => "in store",
      "personal_finance_category" => {
        "detailed" => "Food"
      }
    }

    @category_matcher.expects(:match).with("Food").returns(categories(:food_and_drink))

    # Create an existing entry
    @plaid_account.current_account.entries.create!(
      external_id: existing_plaid_id,
      source: "plaid",
      amount: 100,
      currency: "USD",
      date: Date.current,
      name: "Amazon",
      entryable: Transaction.new
    )

    processor = PlaidEntry::Processor.new(
      plaid_transaction,
      plaid_account: @plaid_account,
      category_matcher: @category_matcher
    )

    assert_no_difference [ "Entry.count", "Transaction.count", "ProviderMerchant.count" ] do
      processor.process
    end

    entry = Entry.find_by!(external_id: existing_plaid_id, source: "plaid")

    assert_equal 200, entry.amount
    assert_equal "USD", entry.currency
    assert_equal 1.day.ago.to_date, entry.date
    assert_equal "AMZN Mktp US*UPDATED", entry.name
    assert_equal categories(:food_and_drink).id, entry.transaction.category_id
    assert_equal "in store", entry.transaction.extra.dig("plaid", "payment_channel")
  end

  test "skips category matcher when account.enable_category_matcher is false" do
    @plaid_account.current_account.update!(enable_category_matcher: false)

    plaid_transaction = {
      "transaction_id" => "456",
      "merchant_name" => "Amazon",
      "amount" => 100,
      "date" => Date.current,
      "iso_currency_code" => "USD",
      "personal_finance_category" => {
        "detailed" => "Food"
      },
      "merchant_entity_id" => "456"
    }

    @category_matcher.expects(:match).never

    processor = PlaidEntry::Processor.new(
      plaid_transaction,
      plaid_account: @plaid_account,
      category_matcher: @category_matcher
    )

    assert_difference [ "Entry.count", "Transaction.count" ], 1 do
      processor.process
    end

    entry = Entry.order(created_at: :desc).first
    assert_nil entry.transaction.category_id
  end
end
