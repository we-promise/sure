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

  test "bulk_update! touches the assigned category's last_used_at" do
    entry = create_transaction(account: accounts(:depository))
    category = categories(:income)
    assert_nil category.last_used_at

    Entry.where(id: entry.id).bulk_update!({ category_id: category.id })

    assert_not_nil category.reload.last_used_at
  end

  test "bulk_update! reuses the preloaded emi_plan association instead of querying per row" do
    purchase_entry = create_transaction(amount: 1200, name: "Laptop", account: accounts(:depository))
    plan = EmiPlan.build!(entry: purchase_entry, interest_rate: 0, tenure_months: 3, processing_fee: 0)
    installment_ids = plan.installment_entries.pluck(:id)
    category = categories(:income)

    queries = []
    callback = lambda do |_name, _started, _finished, _unique_id, payload|
      next if payload[:cached]
      next if %w[SCHEMA TRANSACTION].include?(payload[:name])

      queries << payload[:sql].squish
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      Entry.where(id: installment_ids).bulk_update!({ category_id: category.id })
    end

    # emi_date_locked? (called once per row inside bulk_update!'s loop) used
    # to run `EmiPlan.find_by(id: emi_plan_id)` directly, bypassing the
    # `:originated_emi_plan` preload entirely and issuing one extra SELECT
    # per installment -- 3 rows here would mean 3 such queries. With the
    # emi_plan association reused (and preloaded alongside
    # originated_emi_plan), loading it should cost exactly one batched
    # query total for all 3 rows, the same as the existing
    # originated_emi_plan preload -- not one query per row. Match on the
    # unquoted table name too since Rails' preloader can render this as
    # either `emi_plans` or "emi_plans" depending on the query shape.
    emi_plan_lookups = queries.select { |sql| sql.downcase.match?(/from\s+"?emi_plans"?/) }
    assert_equal 2, emi_plan_lookups.size,
      "Expected exactly 2 batched emi_plans queries (one per preloaded association, " \
      "covering all 3 installment rows), not one query per row. Got:\n#{emi_plan_lookups.join("\n")}"
  end
end
