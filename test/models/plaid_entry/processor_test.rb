require "test_helper"

class PlaidEntry::ProcessorTest < ActiveSupport::TestCase
  setup do
    @plaid_account = plaid_accounts(:one)
    @category_matcher = mock("PlaidAccount::Transactions::CategoryMatcher")
  end

  test "creates new entry transaction" do
    plaid_transaction = {
      "transaction_id" => "123",
      "merchant_name" => "Amazon", # this is used for merchant and entry name
      "amount" => 100,
      "date" => Date.current,
      "iso_currency_code" => "USD",
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
    assert_equal "Amazon", entry.name
    assert_equal categories(:food_and_drink).id, entry.transaction.category_id

    provider_merchant = ProviderMerchant.order(created_at: :desc).first

    assert_equal "Amazon", provider_merchant.name
  end

  test "updates existing entry transaction" do
    existing_plaid_id = "existing_plaid_id"

    plaid_transaction = {
      "transaction_id" => existing_plaid_id,
      "merchant_name" => "Amazon", # this is used for merchant and entry name
      "amount" => 200, # Changed amount will be updated
      "date" => 1.day.ago.to_date, # Changed date will be updated
      "iso_currency_code" => "USD",
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

    entry = Entry.order(created_at: :desc).first

    assert_equal 200, entry.amount
    assert_equal "USD", entry.currency
    assert_equal 1.day.ago.to_date, entry.date
    assert_equal "Amazon", entry.name
    assert_equal categories(:food_and_drink).id, entry.transaction.category_id
  end

  # extra is deep-merged on import, so omitting a key would leave a stale value
  # behind forever once Plaid stops sending it.
  test "clears provider metadata that Plaid no longer sends" do
    base = {
      "transaction_id" => "clears-metadata",
      "merchant_name" => "Amazon",
      "amount" => 10,
      "date" => Date.current,
      "iso_currency_code" => "USD",
      "payment_channel" => "online",
      "payment_meta" => { "reference_number" => "REF-1" },
      "personal_finance_category" => { "detailed" => "Food" },
      "merchant_entity_id" => "clears-metadata-merchant"
    }

    @category_matcher.stubs(:match).returns(categories(:food_and_drink))

    PlaidEntry::Processor.new(base, plaid_account: @plaid_account, category_matcher: @category_matcher).process

    entry = Entry.find_by!(external_id: "clears-metadata", source: "plaid")
    assert_equal "online", entry.transaction.extra.dig("plaid", "payment_channel")

    # Plaid drops both fields on a later sync
    PlaidEntry::Processor.new(
      base.except("payment_channel", "payment_meta"),
      plaid_account: @plaid_account,
      category_matcher: @category_matcher
    ).process

    plaid_extra = entry.reload.transaction.extra.fetch("plaid")
    assert_nil plaid_extra["payment_channel"]
    assert_nil plaid_extra["payment_meta"]
  end

  # deep_merge recurses into nested hashes, so dropping only the whole branch is
  # not enough: a single key removed from payment_meta has to disappear too.
  test "clears a nested metadata key while keeping its siblings" do
    base = {
      "transaction_id" => "clears-nested-key",
      "merchant_name" => "Amazon",
      "amount" => 10,
      "date" => Date.current,
      "iso_currency_code" => "USD",
      "payment_meta" => { "payee" => "Amazon", "reference_number" => "REF-1" },
      "personal_finance_category" => { "detailed" => "Food" },
      "merchant_entity_id" => "clears-nested-merchant"
    }

    @category_matcher.stubs(:match).returns(categories(:food_and_drink))

    PlaidEntry::Processor.new(base, plaid_account: @plaid_account, category_matcher: @category_matcher).process

    entry = Entry.find_by!(external_id: "clears-nested-key", source: "plaid")
    assert_equal "Amazon", entry.transaction.extra.dig("plaid", "payment_meta", "payee")

    # Plaid keeps reference_number but stops sending payee
    PlaidEntry::Processor.new(
      base.merge("payment_meta" => { "reference_number" => "REF-2" }),
      plaid_account: @plaid_account,
      category_matcher: @category_matcher
    ).process

    assert_equal({ "reference_number" => "REF-2" }, entry.reload.transaction.extra.dig("plaid", "payment_meta"))
  end

  # Replacing the plaid branch must not disturb another provider's namespace on
  # the same transaction.
  test "replacing the plaid namespace leaves other providers alone" do
    plaid_transaction = {
      "transaction_id" => "other-provider-kept",
      "merchant_name" => "Amazon",
      "amount" => 10,
      "date" => Date.current,
      "iso_currency_code" => "USD",
      "payment_channel" => "online",
      "personal_finance_category" => { "detailed" => "Food" },
      "merchant_entity_id" => "other-provider-merchant"
    }

    @category_matcher.stubs(:match).returns(categories(:food_and_drink))

    PlaidEntry::Processor.new(
      plaid_transaction, plaid_account: @plaid_account, category_matcher: @category_matcher
    ).process

    entry = Entry.find_by!(external_id: "other-provider-kept", source: "plaid")
    entry.transaction.update!(extra: entry.transaction.extra.merge("simplefin" => { "memo" => "keep me" }))

    PlaidEntry::Processor.new(
      plaid_transaction, plaid_account: @plaid_account, category_matcher: @category_matcher
    ).process

    assert_equal "keep me", entry.reload.transaction.extra.dig("simplefin", "memo")
    assert_equal "online", entry.transaction.extra.dig("plaid", "payment_channel")
  end

  test "treats whitespace-only provider values as blank" do
    plaid_transaction = {
      "transaction_id" => "blank-values",
      "merchant_name" => "Amazon",
      "amount" => 10,
      "date" => Date.current,
      "iso_currency_code" => "USD",
      "payment_meta" => { "payee" => "   ", "reference_number" => "REF-1" },
      "personal_finance_category" => { "detailed" => "Food" },
      "merchant_entity_id" => "blank-values-merchant"
    }

    @category_matcher.stubs(:match).returns(categories(:food_and_drink))

    PlaidEntry::Processor.new(
      plaid_transaction, plaid_account: @plaid_account, category_matcher: @category_matcher
    ).process

    entry = Entry.find_by!(external_id: "blank-values", source: "plaid")

    assert_equal({ "reference_number" => "REF-1" }, entry.transaction.extra.dig("plaid", "payment_meta"))
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

  test "stores provider payment metadata on the transaction" do
    plaid_transaction = {
      "transaction_id" => "with-metadata",
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
      "merchant_entity_id" => "with-metadata-merchant"
    }

    @category_matcher.expects(:match).with("Food").returns(categories(:food_and_drink))

    processor = PlaidEntry::Processor.new(
      plaid_transaction,
      plaid_account: @plaid_account,
      category_matcher: @category_matcher
    )

    processor.process

    entry = Entry.find_by!(external_id: "with-metadata", source: "plaid")
    plaid_extra = entry.transaction.extra.fetch("plaid")

    assert_equal "AMZN Mktp US*AB12CD SEATTLE WA", plaid_extra["original_description"]
    assert_equal "online", plaid_extra["payment_channel"]
    # Blank sub-values are dropped rather than stored as nulls
    assert_equal({ "payee" => "Amazon", "reference_number" => "REF-1" }, plaid_extra["payment_meta"])
    assert_equal 1, plaid_extra["counterparties"].size
    assert_equal "Amazon", plaid_extra["counterparties"].first["name"]
    assert_nil plaid_extra["transaction_code"]
  end

  # merchant_name alone collapses every Target purchase into "Target", which
  # leaves nothing for a rule to distinguish the variants by.
  test "combines merchant name and original description when both are present" do
    plaid_transaction = {
      "transaction_id" => "combined-name",
      "merchant_name" => "Target",
      "original_description" => "TARGET 00023 SAN MATEO CA",
      "amount" => 100,
      "date" => Date.current,
      "iso_currency_code" => "USD",
      "personal_finance_category" => { "detailed" => "Food" },
      "merchant_entity_id" => "combined-name-merchant"
    }

    @category_matcher.expects(:match).with("Food").returns(categories(:food_and_drink))

    PlaidEntry::Processor.new(
      plaid_transaction, plaid_account: @plaid_account, category_matcher: @category_matcher
    ).process

    entry = Entry.find_by!(external_id: "combined-name", source: "plaid")

    assert_equal "Target - TARGET 00023 SAN MATEO CA", entry.name
    # The merchant record still carries the clean name, so grouping is unaffected.
    assert_equal "Target", entry.transaction.merchant.name
  end

  test "uses the merchant name alone when there is no original description" do
    plaid_transaction = {
      "transaction_id" => "merchant-only",
      "merchant_name" => "Amazon",
      "amount" => 50,
      "date" => Date.current,
      "iso_currency_code" => "USD",
      "personal_finance_category" => { "detailed" => "Food" },
      "merchant_entity_id" => "merchant-only-merchant"
    }

    @category_matcher.expects(:match).with("Food").returns(categories(:food_and_drink))

    PlaidEntry::Processor.new(
      plaid_transaction, plaid_account: @plaid_account, category_matcher: @category_matcher
    ).process

    assert_equal "Amazon", Entry.find_by!(external_id: "merchant-only", source: "plaid").name
  end

  test "uses the original description alone when Plaid resolved no merchant" do
    plaid_transaction = {
      "transaction_id" => "description-only",
      "original_description" => "SQ *COFFEE BAR",
      "amount" => 5,
      "date" => Date.current,
      "iso_currency_code" => "USD",
      "personal_finance_category" => { "detailed" => "Food" }
    }

    @category_matcher.expects(:match).with("Food").returns(categories(:food_and_drink))

    PlaidEntry::Processor.new(
      plaid_transaction, plaid_account: @plaid_account, category_matcher: @category_matcher
    ).process

    assert_equal "SQ *COFFEE BAR", Entry.find_by!(external_id: "description-only", source: "plaid").name
  end

  test "does not repeat itself when both values are identical" do
    plaid_transaction = {
      "transaction_id" => "identical-name",
      "merchant_name" => "Netflix",
      "original_description" => "Netflix",
      "amount" => 15,
      "date" => Date.current,
      "iso_currency_code" => "USD",
      "personal_finance_category" => { "detailed" => "Food" },
      "merchant_entity_id" => "identical-name-merchant"
    }

    @category_matcher.expects(:match).with("Food").returns(categories(:food_and_drink))

    PlaidEntry::Processor.new(
      plaid_transaction, plaid_account: @plaid_account, category_matcher: @category_matcher
    ).process

    assert_equal "Netflix", Entry.find_by!(external_id: "identical-name", source: "plaid").name
  end

  # A categorized entry keeps its name when Plaid resends it, but its Plaid
  # namespace is refreshed. If the description the name was built from were
  # refreshed with it, the rule filter would rebuild a name that no longer matches
  # the real one: "= Target" would stop matching and "!= Target" would start.
  # Banks can rewrite a pending transaction's description as it settles, and
  # people categorize pending transactions, so this is a real path.
  test "exact name rules keep matching after the description changes on a categorized entry" do
    first = plaid_transaction("drifting", description: "TARGET 00023")
    @category_matcher.stubs(:match).returns(categories(:food_and_drink))

    PlaidEntry::Processor.new(first, plaid_account: @plaid_account, category_matcher: @category_matcher).process
    entry = Entry.find_by!(external_id: "drifting", source: "plaid")
    entry.mark_user_modified!

    resent = plaid_transaction("drifting", description: "TARGET 00023 SAN MATEO CA")
    PlaidEntry::Processor.new(resent, plaid_account: @plaid_account, category_matcher: @category_matcher).process
    entry.reload

    assert_equal "Target - TARGET 00023", entry.name, "a categorized entry keeps its name"
    assert_equal "TARGET 00023", entry.transaction.extra.dig("plaid", "original_description"),
      "the description the name was built from stays with it"

    assert_includes name_rule_matches("=", "Target"), entry.transaction.id
    assert_not_includes name_rule_matches("!=", "Target"), entry.transaction.id
  end

  private
    # @param id [String] Plaid's transaction id
    # @param description [String] the bank's original description
    # @return [Hash] a Plaid transaction naming Target as the merchant
    def plaid_transaction(id, description:)
      {
        "transaction_id" => id,
        "merchant_name" => "Target",
        "original_description" => description,
        "amount" => 25,
        "date" => Date.current,
        "iso_currency_code" => "USD",
        "personal_finance_category" => { "detailed" => "Food" },
        "merchant_entity_id" => "#{id}-merchant"
      }
    end

    # @param operator [String] "=" or "!="
    # @param value [String] the value the rule compares against
    # @return [Array<String>] transaction ids the rule selects in this account
    def name_rule_matches(operator, value)
      condition = Rule::Condition.new(
        rule: rules(:one), condition_type: "transaction_name", operator: operator, value: value
      )
      condition.apply(condition.prepare(@plaid_account.current_account.transactions)).map(&:id)
    end
end
