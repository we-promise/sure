require "test_helper"

# This filter exists because Rule::ConditionFilter::TransactionDetails searches every value
# in transactions.extra at any depth, so a rule for an MCC also fires on a provider id or
# payment reference that merely contains those digits. The key-scoped behaviour below, and
# that it refuses the matches the unscoped filter would make, is the whole of its
# correctness.
class Rule::ConditionFilter::TransactionAdditionalDetailTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @rule = rules(:one)
    @account = @family.accounts.create!(
      name: "Rule test", balance: 1000, currency: "USD", accountable: Depository.new
    )
  end

  # The case this was built for: a Redbark supermarket shop arrives as FOOD_AND_DRINK with
  # MCC 5411, and the user wants those split out into Groceries by rule.
  test "matches a transaction whose named field equals the value" do
    groceries = redbark_entry("woolies", merchant_category_code: "5411")
    redbark_entry("hotel", merchant_category_code: "7011")

    assert_equal [ groceries.id ], matching_entry_ids(value: "merchant_category_code=5411")
  end

  # The reason the unscoped Details filter is not good enough: "5411" appears inside this
  # row's provider id, and nowhere in its MCC.
  test "does not match the value appearing in a different field" do
    redbark_entry("noise", merchant_category_code: "7011", id: "tx-5411-abc")

    assert_empty matching_entry_ids(value: "merchant_category_code=5411")
  end

  test "does not match a transaction lacking the field entirely" do
    create_transaction(account: @account, name: "manual")

    assert_empty matching_entry_ids(value: "merchant_category_code=5411")
  end

  test "finds the field whatever provider namespace it sits under" do
    entry = create_transaction(account: @account, name: "monobank-ish")
    entry.transaction.update!(extra: { "monobank" => { "merchant_category_code" => "5411" } })

    assert_equal [ entry.id ], matching_entry_ids(value: "merchant_category_code=5411")
  end

  # A bare key is the "does this transaction carry the field at all" form.
  test "matches on field presence when no value is given" do
    with_mcc = redbark_entry("has-mcc", merchant_category_code: "5411")
    create_transaction(account: @account, name: "no-mcc")

    assert_equal [ with_mcc.id ], matching_entry_ids(value: "merchant_category_code")
  end

  # A field the provider sent as null is present but empty, which is not the same as a
  # field it never sent. `->> key IS NOT NULL` cannot tell those apart -- it reports both
  # as absent -- so the presence check uses jsonb_exists.
  test "presence matches a field whose value is JSON null" do
    present_but_null = create_transaction(account: @account, name: "null-mcc")
    present_but_null.transaction.update!(
      extra: { "redbark" => { "merchant_category_code" => nil } }
    )

    assert_equal [ present_but_null.id ], matching_entry_ids(value: "merchant_category_code")
  end

  test "presence does not match a transaction whose extra omits the field" do
    other_field = create_transaction(account: @account, name: "other-field")
    other_field.transaction.update!(extra: { "redbark" => { "reference" => "abc" } })

    assert_empty matching_entry_ids(value: "merchant_category_code")
  end

  # A null value is present, but it is not equal to anything and contains nothing.
  test "a JSON null value satisfies neither equality nor contains" do
    entry = create_transaction(account: @account, name: "null-mcc")
    entry.transaction.update!(extra: { "redbark" => { "merchant_category_code" => nil } })

    assert_empty matching_entry_ids(value: "merchant_category_code=5411")
    assert_empty matching_entry_ids(operator: "like", value: "merchant_category_code=5411")
  end

  test "equality does not match a value that merely contains the target" do
    redbark_entry("padded", merchant_category_code: "15411")

    assert_empty matching_entry_ids(value: "merchant_category_code=5411")
  end

  test "the contains operator matches a partial value" do
    partial = redbark_entry("padded", merchant_category_code: "15411")

    assert_equal [ partial.id ], matching_entry_ids(operator: "like", value: "merchant_category_code=5411")
  end

  # Only the first separator splits, so a value carrying "=" survives intact.
  test "a value containing the separator is kept whole" do
    entry = create_transaction(account: @account, name: "ref")
    entry.transaction.update!(extra: { "redbark" => { "reference" => "a=b=c" } })

    assert_equal [ entry.id ], matching_entry_ids(value: "reference=a=b=c")
  end

  test "a blank value matches nothing" do
    redbark_entry("woolies", merchant_category_code: "5411")

    assert_empty matching_entry_ids(value: "")
    assert_empty matching_entry_ids(value: "   ")
  end

  # The value is compared literally, so LIKE metacharacters cannot widen the match.
  test "wildcards in the value are escaped" do
    redbark_entry("woolies", merchant_category_code: "5411")

    assert_empty matching_entry_ids(operator: "like", value: "merchant_category_code=%")
  end

  test "rejects an operator it does not offer" do
    assert_raises Rule::ConditionFilter::UnsupportedOperatorError do
      matching_entry_ids(operator: "matches_regex", value: "merchant_category_code=5411")
    end
  end

  private
    # @return [Entry] a Redbark-shaped row carrying the fields the processor stores
    def redbark_entry(name, merchant_category_code:, id: nil)
      entry = create_transaction(
        account: @account, name: name, source: "redbark", external_id: "redbark_#{name}"
      )

      entry.transaction.update!(extra: { "redbark" => {
        "id" => id || "tx-#{name}",
        "merchant_category_code" => merchant_category_code
      } })

      entry
    end

    # @return [Array<String>] entry ids the condition selects, for this account only
    def matching_entry_ids(value:, operator: "=")
      condition = Rule::Condition.new(
        rule: @rule,
        condition_type: "transaction_additional_detail",
        operator: operator,
        value: value
      )

      scope = condition.apply(condition.prepare(@account.transactions))
      scope.map { |transaction| transaction.entry.id }
    end
end
