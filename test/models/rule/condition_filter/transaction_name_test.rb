require "test_helper"

# Plaid names now carry the bank's description after a separator, so `=` and `!=`
# match a Plaid row on the merchant half too. What must NOT change is everything
# else: other sources, other operators, and case sensitivity. That boundary is
# the whole of this filter's correctness.
class Rule::ConditionFilter::TransactionNameTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @rule = rules(:one)
    @account = @family.accounts.create!(
      name: "Rule test", balance: 1000, currency: "USD", accountable: Depository.new
    )
  end

  test "an exact rule still matches the Plaid row whose name grew a description" do
    plaid = plaid_entry(name: "Target - TARGET 00023 SAN MATEO CA",
                        original_description: "TARGET 00023 SAN MATEO CA")

    assert_equal [ plaid.id ], matching_entry_ids(operator: "=", value: "Target")
  end

  # Existing rows keep their short names: a Plaid sync only processes `added` and
  # `modified` from the stored cursor, so history is not rewritten.
  test "an exact rule still matches a Plaid row that kept its short name" do
    plaid = plaid_entry(name: "Target")

    assert_equal [ plaid.id ], matching_entry_ids(operator: "=", value: "Target")
  end

  # The reviewer's case on #3450: widening every exact rule in a Plaid family
  # would have made `= "Rent"` start matching this.
  test "an exact rule does not match a manual row that merely contains the value" do
    manual_entry(name: "Rent insurance")
    manual_entry(name: "Rent")

    matched = matching_entry_ids(operator: "=", value: "Rent")

    assert_equal [ "Rent" ], Entry.where(id: matched).pluck(:name)
  end

  # The separator is what identifies the combined form. Without the source gate a
  # manual entry shaped like one would be matched too.
  test "an exact rule does not match a non-Plaid row that looks combined" do
    manual_entry(name: "Rent - APARTMENT 4B")

    assert_empty matching_entry_ids(operator: "=", value: "Rent")
  end

  # Plaid resolves no merchant for plenty of ACH, transfer and fee rows, so their
  # name is the bank's description alone and this change never touches it. Those
  # descriptions are also the ones most likely to contain a dash. Matching on the
  # separator by pattern could not tell that dash from the one #name inserts, and
  # broke rules on rows the feature does not even rename.
  test "an exact rule does not match a Plaid row whose own description has a dash" do
    plaid_entry(name: "ACH - PAYROLL DEPOSIT ACME CORP",
                original_description: "ACH - PAYROLL DEPOSIT ACME CORP")

    assert_empty matching_entry_ids(operator: "=", value: "ACH")
  end

  test "a not-equal rule still returns a Plaid row whose own description has a dash" do
    row = plaid_entry(name: "ACH - PAYROLL DEPOSIT ACME CORP",
                      original_description: "ACH - PAYROLL DEPOSIT ACME CORP")

    assert_includes matching_entry_ids(operator: "!=", value: "ACH"), row.id
  end

  test "an exact rule stays case sensitive" do
    plaid_entry(name: "Target - TARGET 00023 SAN MATEO CA",
                original_description: "TARGET 00023 SAN MATEO CA")

    assert_empty matching_entry_ids(operator: "=", value: "target")
  end

  test "a not-equal rule excludes the Plaid row whose name grew a description" do
    plaid_entry(name: "Target - TARGET 00023 SAN MATEO CA",
                original_description: "TARGET 00023 SAN MATEO CA")
    keeper = plaid_entry(name: "Costco - COSTCO WHSE 0112",
                         original_description: "COSTCO WHSE 0112")

    assert_equal [ keeper.id ], matching_entry_ids(operator: "!=", value: "Target")
  end

  # entries.source is NULL for manual rows, so the Plaid arm of the predicate is
  # NULL and a bare NOT(...) would discard them. Guards the COALESCE.
  #
  # The second row is the one that does the guarding. For "Rent insurance" the
  # composed comparison is false, and NULL AND FALSE is FALSE, so that row
  # survives the negation with or without the COALESCE. Only a manual row shaped
  # like a combined name reaches NULL AND TRUE, which is NULL.
  test "a not-equal rule still returns manual rows" do
    manual = manual_entry(name: "Rent insurance")
    combined_looking = manual_entry(name: "Target - APARTMENT 4B")

    matched = matching_entry_ids(operator: "!=", value: "Target")

    assert_includes matched, manual.id
    assert_includes matched, combined_looking.id
  end

  test "substring operators are untouched" do
    plaid_entry(name: "Target - TARGET 00023 SAN MATEO CA",
                original_description: "TARGET 00023 SAN MATEO CA")
    manual = manual_entry(name: "Rent insurance")

    assert_includes matching_entry_ids(operator: "like", value: "insurance"), manual.id
    assert_empty matching_entry_ids(operator: "like", value: "Costco")
  end

  # A value carrying LIKE metacharacters must be compared literally, not as a
  # pattern, or `= "100% Chiropractic"` would match anything.
  test "wildcards in the value are escaped" do
    plaid_entry(name: "Discount - 50% OFF EVERYTHING",
                original_description: "50% OFF EVERYTHING")

    assert_empty matching_entry_ids(operator: "=", value: "%")
  end

  private
    # PlaidEntry::Processor#process writes the name and the stored
    # original_description in one import_transaction call, so a combined name
    # never exists without the description that built it. Tests that skip the
    # description are describing a row production cannot produce.
    #
    # @param name [String] the entry name to store
    # @param original_description [String, nil] what the bank called it, stored
    #   under extra["plaid"] the way the processor stores it
    # @return [Entry] a row carrying Plaid provenance, so the source gated arm applies
    def plaid_entry(name:, original_description: nil)
      entry = create_transaction(
        account: @account,
        name: name,
        source: PlaidEntry::Processor::SOURCE,
        external_id: "ext-#{name.parameterize}"
      )

      if original_description
        entry.transaction.update!(extra: { "plaid" => { "original_description" => original_description } })
      end

      entry
    end

    # @param name [String] the entry name to store
    # @return [Entry] a row with no source, which is what makes entries.source NULL
    def manual_entry(name:)
      create_transaction(account: @account, name: name)
    end

    # @return [Array<String>] entry ids the condition selects, for this account only
    def matching_entry_ids(operator:, value:)
      condition = Rule::Condition.new(
        rule: @rule, condition_type: "transaction_name", operator: operator, value: value
      )

      scope = condition.apply(condition.prepare(@account.transactions))
      scope.map { |transaction| transaction.entry.id }
    end
end
