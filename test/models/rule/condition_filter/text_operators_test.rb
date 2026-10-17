require "test_helper"

# starts_with / ends_with / matches_regex on the text filters. The boundary that
# matters is what each one does NOT match: a prefix operator must not behave
# like `contains`, and LIKE wildcards in the user's value must stay literal.
class Rule::ConditionFilter::TextOperatorsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @rule = rules(:one)
    @account = @family.accounts.create!(
      name: "Operators test", balance: 1000, currency: "USD", accountable: Depository.new
    )
  end

  test "starts_with matches the prefix and not a mid-string occurrence" do
    prefix = create_transaction(account: @account, name: "Uber Eats order")
    mid = create_transaction(account: @account, name: "Not Uber Eats")

    matched = matching_names(condition_type: "transaction_name", operator: "starts_with", value: "uber")

    assert_includes matched, prefix.name
    assert_not_includes matched, mid.name
  end

  test "ends_with matches the suffix and not a mid-string occurrence" do
    suffix = create_transaction(account: @account, name: "Monthly Netflix")
    mid = create_transaction(account: @account, name: "Netflix monthly")

    matched = matching_names(condition_type: "transaction_name", operator: "ends_with", value: "netflix")

    assert_includes matched, suffix.name
    assert_not_includes matched, mid.name
  end

  test "starts_with and ends_with treat LIKE wildcards in the value literally" do
    literal = create_transaction(account: @account, name: "50% off store")
    other = create_transaction(account: @account, name: "500 off store")

    matched = matching_names(condition_type: "transaction_name", operator: "starts_with", value: "50%")

    assert_includes matched, literal.name
    assert_not_includes matched, other.name

    underscore = create_transaction(account: @account, name: "shop_1")
    wildcard_hit = create_transaction(account: @account, name: "shopX1")

    matched = matching_names(condition_type: "transaction_name", operator: "ends_with", value: "p_1")

    assert_includes matched, underscore.name
    assert_not_includes matched, wildcard_hit.name
  end

  test "starts_with ignores the whitespace the stored name collected" do
    padded = create_transaction(account: @account, name: "  Coffee   Shop")

    matched = matching_names(condition_type: "transaction_name", operator: "starts_with", value: "Coffee Shop")

    assert_includes matched, padded.name
  end

  test "starts_with and ends_with also work on notes" do
    entry = create_transaction(account: @account, name: "Plain")
    entry.update!(notes: "Reimbursable trip")

    assert_equal [ "Plain" ], matching_names(condition_type: "transaction_notes", operator: "starts_with", value: "reimb")
    assert_equal [ "Plain" ], matching_names(condition_type: "transaction_notes", operator: "ends_with", value: "TRIP")
    assert_empty matching_names(condition_type: "transaction_notes", operator: "ends_with", value: "reimb")
  end

  test "matches_regex matches case-insensitively and anchors are honoured" do
    hit = create_transaction(account: @account, name: "AMZN Mktp US*2K4")
    miss = create_transaction(account: @account, name: "Not AMZN Mktp")

    matched = matching_names(condition_type: "transaction_name", operator: "matches_regex", value: '^amzn\s+mktp')

    assert_includes matched, hit.name
    assert_not_includes matched, miss.name
  end

  # The stored name is collapsed to single spaces for text operators, so a pattern
  # that spells two spaces can only match if the pattern itself is left untouched.
  test "matches_regex value is not whitespace-normalised" do
    create_transaction(account: @account, name: "A  B")

    assert_empty matching_names(condition_type: "transaction_name", operator: "matches_regex", value: "A  B")
    assert_equal [ "A  B" ], matching_names(condition_type: "transaction_name", operator: "matches_regex", value: "A B")
  end

  test "the text type offers the new operators" do
    operators = Rule::ConditionFilter::OPERATORS_MAP.fetch("text").map(&:last)

    assert_includes operators, "starts_with"
    assert_includes operators, "ends_with"
    assert_includes operators, "matches_regex"
  end

  test "the transaction name and notes filters offer them, details and number filters do not" do
    %w[transaction_name transaction_notes].each do |key|
      offered = @rule.registry.get_filter!(key).operators.map(&:last)
      assert_includes offered, "matches_regex", key
    end

    details = @rule.registry.get_filter!("transaction_details").operators.map(&:last)
    assert_equal %w[like = is_null], details

    amount = @rule.registry.get_filter!("transaction_amount").operators.map(&:last)
    assert_not_includes amount, "starts_with"
  end

  private
    def matching_names(condition_type:, operator:, value:)
      condition = Rule::Condition.new(rule: @rule, condition_type: condition_type, operator: operator, value: value)
      scope = condition.prepare(@account.transactions)
      condition.apply(scope).includes(:entry).map { |t| t.entry.name }.uniq
    end
end
