require "test_helper"

class TransactionTest < ActiveSupport::TestCase
  include EntriesTestHelper

  test "pending? is true when extra.simplefin.pending is truthy" do
    transaction = Transaction.new(extra: { "simplefin" => { "pending" => true } })

    assert transaction.pending?
  end

  test "pending? is true when extra.plaid.pending is truthy" do
    transaction = Transaction.new(extra: { "plaid" => { "pending" => "true" } })

    assert transaction.pending?
  end

  test "pending? is true when extra.lunchflow.pending is truthy" do
    transaction = Transaction.new(extra: { "lunchflow" => { "pending" => true } })

    assert transaction.pending?
  end

  test "pending? is false when no provider pending metadata is present" do
    transaction = Transaction.new(extra: { "plaid" => { "pending" => false } })

    assert_not transaction.pending?
  end

  test "pending? returns true for enable_banking pending transactions" do
    transaction = Transaction.new(extra: { "enable_banking" => { "pending" => true } })

    assert transaction.pending?
  end

  test "pending? returns false for enable_banking non-pending transactions" do
    transaction = Transaction.new(extra: { "enable_banking" => { "pending" => false } })

    assert_not transaction.pending?
  end

  test "investment_contribution is a valid kind" do
    transaction = Transaction.new(kind: "investment_contribution")

    assert_equal "investment_contribution", transaction.kind
    assert transaction.investment_contribution?
  end

  test "TRANSFER_KINDS constant matches transfer? method" do
    Transaction::TRANSFER_KINDS.each do |kind|
      assert Transaction.new(kind: kind).transfer?, "#{kind} should be a transfer kind"
    end

    non_transfer_kinds = Transaction.kinds.keys - Transaction::TRANSFER_KINDS
    non_transfer_kinds.each do |kind|
      assert_not Transaction.new(kind: kind).transfer?, "#{kind} should NOT be a transfer kind"
    end
  end

  test "all transaction kinds are valid" do
    valid_kinds = %w[standard funds_movement cc_payment loan_payment one_time investment_contribution]

    valid_kinds.each do |kind|
      transaction = Transaction.new(kind: kind)
      assert_equal kind, transaction.kind, "#{kind} should be a valid transaction kind"
    end
  end

  test "ACTIVITY_LABELS contains all valid labels" do
    assert_includes Transaction::ACTIVITY_LABELS, "Buy"
    assert_includes Transaction::ACTIVITY_LABELS, "Sell"
    assert_includes Transaction::ACTIVITY_LABELS, "Sweep In"
    assert_includes Transaction::ACTIVITY_LABELS, "Sweep Out"
    assert_includes Transaction::ACTIVITY_LABELS, "Dividend"
    assert_includes Transaction::ACTIVITY_LABELS, "Reinvestment"
    assert_includes Transaction::ACTIVITY_LABELS, "Interest"
    assert_includes Transaction::ACTIVITY_LABELS, "Fee"
    assert_includes Transaction::ACTIVITY_LABELS, "Transfer"
    assert_includes Transaction::ACTIVITY_LABELS, "Contribution"
    assert_includes Transaction::ACTIVITY_LABELS, "Withdrawal"
    assert_includes Transaction::ACTIVITY_LABELS, "Exchange"
    assert_includes Transaction::ACTIVITY_LABELS, "Other"
  end

  test "exchange_rate getter returns nil when extra is nil" do
    transaction = Transaction.new
    assert_nil transaction.exchange_rate
  end

  test "exchange_rate setter stores normalized numeric value" do
    transaction = Transaction.new
    transaction.exchange_rate = "1.5"

    assert_equal 1.5, transaction.exchange_rate
  end

  test "exchange_rate setter marks invalid input" do
    transaction = Transaction.new
    transaction.exchange_rate = "not a number"

    assert_equal "not a number", transaction.extra["exchange_rate"]
    assert transaction.extra["exchange_rate_invalid"]
  end

  test "exchange_rate setter rejects non-finite input" do
    transaction = Transaction.new
    transaction.exchange_rate = "Infinity"

    assert_equal "Infinity", transaction.extra["exchange_rate"]
    assert transaction.extra["exchange_rate_invalid"]
  end

  test "exchange_rate setter clears invalid flag for valid input" do
    transaction = Transaction.new
    transaction.exchange_rate = "not a number"
    transaction.exchange_rate = "1.5"

    assert_equal 1.5, transaction.exchange_rate
    assert_equal false, transaction.extra["exchange_rate_invalid"]
  end

  test "exchange_rate validation rejects non-numeric input" do
    transaction = Transaction.new(
      category: categories(:income),
      extra: { "exchange_rate" => "invalid" }
    )
    transaction.exchange_rate = "not a number"

    assert_not transaction.valid?
    assert_includes transaction.errors[:exchange_rate], "must be a number"
  end

  test "exchange_rate validation rejects zero values" do
    transaction = Transaction.new(
      category: categories(:income)
    )
    transaction.exchange_rate = 0

    assert_not transaction.valid?
    assert_includes transaction.errors[:exchange_rate], "must be greater than 0"
  end

  test "exchange_rate validation rejects negative values" do
    transaction = Transaction.new(
      category: categories(:income)
    )
    transaction.exchange_rate = -1.5

    assert_not transaction.valid?
    assert_includes transaction.errors[:exchange_rate], "must be greater than 0"
  end

  test "exchange_rate validation allows positive values" do
    transaction = Transaction.new(
      category: categories(:income)
    )
    transaction.exchange_rate = 1.5

    assert transaction.valid?
  end

  test "activity_security returns the referenced security from extra metadata" do
    security = securities(:aapl)
    transaction = Transaction.new(extra: { "security_id" => security.id })

    assert_equal security, transaction.activity_security
  end

  test "activity_security returns nil when no security metadata is present" do
    transaction = Transaction.new(extra: {})

    assert_nil transaction.activity_security
  end

  test "activity_security refreshes when security metadata changes on the same instance" do
    transaction = Transaction.new(extra: { "security_id" => securities(:aapl).id })

    assert_equal securities(:aapl), transaction.activity_security

    transaction.extra["security_id"] = securities(:msft).id

    assert_equal securities(:msft), transaction.activity_security
  end

  test "record_category_usage! touches the new category's last_used_at" do
    transaction = transactions(:one)
    category = categories(:income)
    assert_nil category.last_used_at

    transaction.update!(category: category)
    transaction.record_category_usage!

    assert_not_nil category.reload.last_used_at
  end

  test "record_category_usage! does nothing when category_id did not change" do
    transaction = transactions(:one)
    category = transaction.category
    assert_nil category.last_used_at

    transaction.reload
    transaction.record_category_usage!

    assert_nil category.reload.last_used_at
  end

  test "record_category_usage! does nothing when category is cleared" do
    transaction = transactions(:one)

    transaction.update!(category: nil)

    assert_nothing_raised { transaction.record_category_usage! }
  end

  test "record_category_usage! is not invoked by rule-driven category enrichment" do
    transaction = transactions(:one)
    category = categories(:income)
    assert_nil category.last_used_at

    transaction.enrich_attribute(:category_id, category.id, source: "rule")

    assert_nil category.reload.last_used_at
  end

  test "name_suggestions_for ranks names and each name's category by frequency" do
    family = families(:dylan_family)
    account = accounts(:depository)
    # entries(:transaction) is named "Starbucks" and its transaction (transactions(:one)) is categorized as food_and_drink

    # "Starbucks" ends up more frequent than "Star Market", and within "Starbucks",
    # food_and_drink ends up more frequent than its one-off income-categorized occurrence.
    2.times { create_transaction(name: "Starbucks", account: account, category: categories(:food_and_drink)) }
    create_transaction(name: "Starbucks", account: account, category: categories(:income))
    create_transaction(name: "Star Market", account: account, category: categories(:income))

    suggestions = family.transactions.name_suggestions_for("star")

    assert_equal [ "Starbucks", "Star Market" ], suggestions.map(&:name)
    assert_equal categories(:food_and_drink), suggestions.first.category
    assert_equal categories(:income), suggestions.second.category
  end

  test "name_suggestions_for counts each transaction once when the caller scope joins account_shares" do
    # TransactionsController#name_suggestions calls this via
    # `family.transactions.merge(Account.accessible_by(user))`. Account.accessible_by does
    # left_joins(:account_shares), and for an account the user owns, its WHERE predicate
    # matches every joined share row regardless of which share it is — so an owned account
    # shared with multiple family members fans out to multiple rows per transaction. Without
    # counting distinct transaction ids, that inflates a name's frequency by however many
    # times its account is shared, letting a rarely-used name outrank a genuinely common one.
    family = families(:dylan_family)
    owner = users(:family_admin)
    shared_account = accounts(:depository) # owned by family_admin; already shared with family_member (fixture)
    unshared_account = accounts(:investment) # owned by family_admin; not shared with anyone

    2.times do |i|
      extra_member = User.create!(
        family: family, email: "extra_member_#{i}@example.com", password: "password123456",
        first_name: "Extra", last_name: "Member #{i}", role: "member"
      )
      AccountShare.create!(account: shared_account, user: extra_member, permission: "read_only", include_in_finances: true)
    end
    # shared_account now has 3 account_shares rows (1 fixture + 2 created above), so its
    # accessible_by join fans out 3x — a single real transaction would inflate to a count of 3.

    create_transaction(name: "Fanout Rare", account: shared_account, category: categories(:food_and_drink))
    2.times { create_transaction(name: "Fanout Common", account: unshared_account, category: categories(:income)) }

    suggestions = family.transactions
      .merge(Account.accessible_by(owner))
      .name_suggestions_for("Fanout")

    assert_equal [ "Fanout Common", "Fanout Rare" ], suggestions.map(&:name)
  end

  test "name_suggestions_for returns an empty array when the query is too short" do
    family = families(:dylan_family)
    assert_equal [], family.transactions.name_suggestions_for("st")
    assert_equal [], family.transactions.name_suggestions_for("  ")
  end

  test "name_suggestions_for returns an empty array when no past transaction matches" do
    family = families(:dylan_family)
    assert_equal [], family.transactions.name_suggestions_for("no such merchant")
  end

  test "name_suggestions_for caps results at 8" do
    family = families(:dylan_family)
    account = accounts(:depository)

    9.times { |i| create_transaction(name: "Merchant #{i}", account: account) }

    suggestions = family.transactions.name_suggestions_for("Merchant")

    assert_equal 8, suggestions.size
  end
end
