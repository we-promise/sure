require "test_helper"

class EntryTest < ActiveSupport::TestCase
  include EntriesTestHelper

  test "chronological ordering uses id as final tie breaker" do
    account = accounts(:depository)
    timestamp = Time.zone.parse("2026-05-05 12:00:00")

    entries = 3.times.map do |index|
      create_transaction(
        account: account,
        name: "Same timestamp transaction #{index}",
        date: Date.new(2026, 5, 5),
        created_at: timestamp,
        updated_at: timestamp
      )
    end

    entry_ids = entries.map(&:id)

    assert_equal entry_ids.sort, Entry.where(id: entry_ids).chronological.pluck(:id)
    assert_equal entry_ids.sort.reverse, Entry.where(id: entry_ids).reverse_chronological.pluck(:id)
  end

  test "uncategorized_transactions includes categorizable transfer kinds and excludes uncategorizable ones" do
    account = accounts(:depository)

    standard = create_transaction(account: account, name: "Uncat standard", amount: 100, kind: "standard")
    loan_payment = create_transaction(account: account, name: "Uncat loan payment", amount: 200, kind: "loan_payment")
    contribution = create_transaction(account: account, name: "Uncat contribution", amount: 300, kind: "investment_contribution")
    funds_movement = create_transaction(account: account, name: "Uncat funds movement", amount: 400, kind: "funds_movement")
    cc_payment = create_transaction(account: account, name: "Uncat cc payment", amount: 500, kind: "cc_payment")

    ids = Entry.where(id: [ standard, loan_payment, contribution, funds_movement, cc_payment ].map(&:id))
               .uncategorized_transactions
               .pluck(:id)

    assert_includes ids, standard.id
    assert_includes ids, loan_payment.id
    assert_includes ids, contribution.id
    assert_not_includes ids, funds_movement.id
    assert_not_includes ids, cc_payment.id
  end
end
