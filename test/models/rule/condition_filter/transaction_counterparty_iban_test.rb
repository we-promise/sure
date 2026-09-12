require "test_helper"

class Rule::ConditionFilter::TransactionCounterpartyIbanTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @rule = rules(:one)
    @account = @family.accounts.create!(name: "Rule test", balance: 1000, currency: "USD", accountable: Depository.new)

    @with_iban = create_transaction(date: Date.current, account: @account, amount: 100, name: "Rent")
    @with_iban.transaction.update!(extra: { "counterparty_iban" => "DE89370400440532013000" }) # pipelock:ignore IBAN

    @with_other_iban = create_transaction(date: Date.current, account: @account, amount: 50, name: "Insurance")
    @with_other_iban.transaction.update!(extra: { "counterparty_iban" => "AT611904300234573201" }) # pipelock:ignore IBAN

    @without_iban = create_transaction(date: Date.current, account: @account, amount: 25, name: "Groceries")

    @with_monobank_iban = create_transaction(date: Date.current, account: @account, amount: 75, name: "Landlord")
    @with_monobank_iban.transaction.update!(extra: { "monobank" => { "counter_iban" => "NL91ABNA0417164300" } }) # pipelock:ignore IBAN

    @rule_scope = @account.transactions
  end

  test "equal_to matches only the transaction with the exact iban" do
    condition = Rule::Condition.new(
      rule: @rule,
      condition_type: "transaction_counterparty_iban",
      operator: "=",
      value: "DE89370400440532013000" # pipelock:ignore IBAN
    )

    filtered = condition.apply(condition.prepare(@rule_scope))

    assert_equal [ @with_iban.transaction.id ], filtered.pluck(:id)
  end

  test "equal_to normalizes a value entered with spaces" do
    condition = Rule::Condition.new(
      rule: @rule,
      condition_type: "transaction_counterparty_iban",
      operator: "=",
      value: "de89 3704 0044 0532 0130 00"
    )

    filtered = condition.apply(condition.prepare(@rule_scope))

    assert_equal [ @with_iban.transaction.id ], filtered.pluck(:id)
  end

  test "equal_to normalizes a value entered with tabs and newlines" do
    condition = Rule::Condition.new(
      rule: @rule,
      condition_type: "transaction_counterparty_iban",
      operator: "=",
      value: "de89\t3704\n0044 0532 0130 00"
    )

    filtered = condition.apply(condition.prepare(@rule_scope))

    assert_equal [ @with_iban.transaction.id ], filtered.pluck(:id)
  end

  test "does not match a substring of a different iban" do
    condition = Rule::Condition.new(
      rule: @rule,
      condition_type: "transaction_counterparty_iban",
      operator: "=",
      value: "370400440532013000"
    )

    filtered = condition.apply(condition.prepare(@rule_scope))

    assert_equal [], filtered.pluck(:id)
  end

  test "is_empty matches transactions without a counterparty iban" do
    condition = Rule::Condition.new(
      rule: @rule,
      condition_type: "transaction_counterparty_iban",
      operator: "is_null"
    )

    filtered = condition.apply(condition.prepare(@rule_scope))

    assert_equal [ @without_iban.transaction.id ], filtered.pluck(:id)
  end

  test "is_not_empty matches transactions with any counterparty iban" do
    condition = Rule::Condition.new(
      rule: @rule,
      condition_type: "transaction_counterparty_iban",
      operator: "is_not_null"
    )

    filtered = condition.apply(condition.prepare(@rule_scope))

    assert_equal [ @with_iban.transaction.id, @with_other_iban.transaction.id, @with_monobank_iban.transaction.id ].sort, filtered.pluck(:id).sort
  end

  test "not_equal_to matches transactions with a different or missing iban" do
    condition = Rule::Condition.new(
      rule: @rule,
      condition_type: "transaction_counterparty_iban",
      operator: "!=",
      value: "DE89370400440532013000" # pipelock:ignore IBAN
    )

    filtered = condition.apply(condition.prepare(@rule_scope))

    assert_equal [ @with_other_iban.transaction.id, @without_iban.transaction.id, @with_monobank_iban.transaction.id ].sort, filtered.pluck(:id).sort
  end

  test "equal_to falls back to monobank's nested counter_iban when the top-level field is absent" do
    condition = Rule::Condition.new(
      rule: @rule,
      condition_type: "transaction_counterparty_iban",
      operator: "=",
      value: "NL91ABNA0417164300" # pipelock:ignore IBAN
    )

    filtered = condition.apply(condition.prepare(@rule_scope))

    assert_equal [ @with_monobank_iban.transaction.id ], filtered.pluck(:id)
  end

  test "equal_to matches a monobank counter_iban stored with spaces and lowercase" do
    # MonobankEntry::Processor stores counter_iban as-is from the provider
    # payload with no normalization (unlike Enable Banking's
    # counterparty_iban), so the stored side needs its own normalization in
    # this filter's SQL -- normalizing only the user-entered value isn't
    # enough if Monobank ever returns something other than clean uppercase.
    unnormalized = create_transaction(date: Date.current, account: @account, amount: 60, name: "Utility")
    unnormalized.transaction.update!(extra: { "monobank" => { "counter_iban" => "nl91 abna 0417 1643 00" } }) # pipelock:ignore IBAN

    condition = Rule::Condition.new(
      rule: @rule,
      condition_type: "transaction_counterparty_iban",
      operator: "=",
      value: "NL91ABNA0417164300" # pipelock:ignore IBAN
    )

    filtered = condition.apply(condition.prepare(@rule_scope))

    # @with_monobank_iban already stores this same IBAN in its clean,
    # canonical form, so it matches too -- the point of this test is that
    # the un-normalized row now matches as well, not that it matches alone.
    assert_equal [ @with_monobank_iban.transaction.id, unnormalized.transaction.id ].sort, filtered.pluck(:id).sort
  end
end
