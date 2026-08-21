require "test_helper"

class EmiPlanTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @entry = create_transaction(
      amount: 1200,
      name: "New Laptop",
      account: accounts(:depository),
      category: categories(:food_and_drink)
    )
  end

  test "build! creates one installment entry per month" do
    plan = EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 12, processing_fee: 0)

    assert_equal 12, plan.installment_entries.count
    assert_equal "emi_purchase", @entry.reload.transaction.kind
  end

  test "0% interest splits principal evenly with rounding absorbed by the last installment" do
    plan = EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 7, processing_fee: 0)

    amounts = plan.installment_entries.pluck(:amount)
    assert_equal plan.principal_amount, amounts.sum
    # First 6 are equal; the 7th absorbs the remainder.
    assert_equal amounts.first(6).uniq.size, 1
  end

  test "amortization schedule sums exactly to principal regardless of interest rate" do
    plan = EmiPlan.new(principal_amount: 1000, interest_rate: 14.5, tenure_months: 9)

    schedule = plan.amortization_schedule
    assert_equal 1000.0, schedule.sum { |s| s[:principal] }.to_f
  end

  test "build! creates a one-time processing fee entry dated today" do
    plan = EmiPlan.build!(entry: @entry, interest_rate: 10, tenure_months: 6, processing_fee: 49)

    fee_entry = plan.processing_fee_entry
    assert_not_nil fee_entry
    assert_equal 49.to_d, fee_entry.amount
    assert_equal @entry.date, fee_entry.date
    assert_equal "emi_fee", fee_entry.transaction.kind
  end

  test "build! skips fee entry when processing_fee is zero" do
    plan = EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 6, processing_fee: 0)

    assert_nil plan.processing_fee_entry
  end

  test "generated entry names use the i18n templates with correct interpolation" do
    plan = EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 3, processing_fee: 15)

    expected_fee_name = I18n.t("emi_plans.generated_entry_names.processing_fee", name: @entry.name)
    assert_equal expected_fee_name, plan.processing_fee_entry.name

    first_installment = plan.installment_entries.first
    expected_installment_name = I18n.t(
      "emi_plans.generated_entry_names.installment",
      name: @entry.name, number: 1, tenure: 3
    )
    assert_equal expected_installment_name, first_installment.name
  end

  test "build! raises when the transaction isn't emi_convertible" do
    @entry.split!([
      { name: "Part 1", amount: 600, category_id: nil },
      { name: "Part 2", amount: 600, category_id: nil }
    ])

    assert_raises(ActiveRecord::RecordInvalid) do
      EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 6, processing_fee: 0)
    end
  end

  test "a second plan cannot be created for an entry that already has one" do
    EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 6, processing_fee: 0)

    # Simulate a race: bypass the emi_convertible? guard entirely (which
    # would normally catch this first) and hit the model-level uniqueness
    # validation directly, the same layer a genuinely concurrent request
    # would reach if it passed the controller's check a moment earlier.
    duplicate = EmiPlan.new(
      entry: @entry,
      account: @entry.account,
      principal_amount: @entry.amount.abs,
      interest_rate: 0,
      tenure_months: 6,
      processing_fee: 0,
      start_date: Date.current + 1.month,
      status: "active"
    )

    refute duplicate.valid?
    assert_includes duplicate.errors[:entry_id], "has already been taken"
  end

  test "installments are dated monthly starting from start_date" do
    start_date = Date.new(2026, 9, 1)
    plan = EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 3, processing_fee: 0, start_date: start_date)

    dates = plan.installment_entries.order(:emi_installment_number).pluck(:date)
    assert_equal [ Date.new(2026, 9, 1), Date.new(2026, 10, 1), Date.new(2026, 11, 1) ], dates
  end

  test "foreclose! removes future installments and settles remaining principal" do
    plan = EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 3, processing_fee: 0, start_date: Date.current - 1.month)

    # First installment is in the past (posted), the rest are future.
    posted_count = plan.posted_installments.count
    future_count = plan.remaining_installments.count
    assert_operator posted_count, :>, 0
    assert_operator future_count, :>, 0

    future_principal = plan.remaining_installments.sum(&:amount)

    plan.foreclose!

    # Posted installments stay untouched, future ones are gone, and — since
    # some installments already posted — a settlement entry appears for the
    # principal that would otherwise have vanished from budget totals.
    assert_equal posted_count + 1, plan.installment_entries.count
    assert_equal "foreclosed", plan.reload.status

    settlement = plan.installment_entries.order(:emi_installment_number).last
    assert_equal future_principal, settlement.amount
    assert_equal Date.current, settlement.date
  end

  test "foreclose! reverts parent kind to standard when no installment ever posted" do
    # start_date in the future so nothing has posted yet
    plan = EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 3, processing_fee: 0, start_date: Date.current + 1.month)

    plan.foreclose!

    assert_equal "standard", @entry.reload.transaction.kind
  end

  test "foreclose! keeps parent excluded once at least one installment posted" do
    plan = EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 3, processing_fee: 0, start_date: Date.current - 1.month)

    plan.foreclose!

    assert_equal "emi_purchase", @entry.reload.transaction.kind
  end

  test "foreclose! creates no settlement entry when nothing is outstanding" do
    # All installments already posted (start_date far enough in the past
    # that every one of the 3 monthly installments has a date <= today) —
    # there's no future principal left to settle.
    plan = EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 3, processing_fee: 0, start_date: Date.current - 4.months)

    assert_equal 0, plan.remaining_installments.count

    assert_no_difference "Entry.count" do
      plan.foreclose!
    end

    assert_equal "foreclosed", plan.reload.status
  end

  test "emi_convertible? is false once already converted" do
    EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 6, processing_fee: 0)

    refute @entry.reload.transaction.emi_convertible?
  end

  test "emi_convertible? is false for income (negative amount) entries" do
    income_entry = create_transaction(amount: -400, name: "Refund", account: accounts(:depository))

    refute income_entry.transaction.emi_convertible?
  end

  test "emi_convertible? is false for investment account transactions" do
    # Investment-account transactions have a separate conversion path
    # (Convert to Trade). Allowing both to apply to the same entry would
    # let a full-value trade and a live EMI installment schedule both
    # count against the same money -- see
    # transactions_controller_test.rb for the trade-side guard.
    investment_entry = create_transaction(amount: 500, name: "Brokerage fee", account: accounts(:investment))

    refute investment_entry.transaction.emi_convertible?
  end

  test "build! raises for an investment account transaction even with a valid tenure" do
    investment_entry = create_transaction(amount: 500, name: "Brokerage fee", account: accounts(:investment))

    assert_no_difference "Entry.count" do
      assert_raises(ActiveRecord::RecordInvalid) do
        EmiPlan.build!(entry: investment_entry, interest_rate: 0, tenure_months: 6, processing_fee: 0)
      end
    end
  end

  test "monthly_installment_amount matches first schedule entry" do
    plan = EmiPlan.build!(entry: @entry, interest_rate: 12, tenure_months: 6, processing_fee: 0)

    assert_equal plan.amortization_schedule.first[:total], plan.monthly_installment_amount.amount
  end

  test "cannot change amount on a converted purchase entry" do
    EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 6, processing_fee: 0)

    @entry.reload.amount = 999
    refute @entry.valid?
    assert_includes @entry.errors[:base], "Amount and date can't be changed on a purchase that's been converted to an EMI plan. Foreclose the plan first."
  end

  test "cannot change date on a converted purchase entry" do
    EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 6, processing_fee: 0)

    @entry.reload.date = Date.current - 1.day
    refute @entry.valid?
    assert_includes @entry.errors[:base], "Amount and date can't be changed on a purchase that's been converted to an EMI plan. Foreclose the plan first."
  end

  test "converted purchase entry can still have its category or name updated" do
    EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 6, processing_fee: 0)

    @entry.reload.name = "New Laptop (updated)"
    assert @entry.valid?
  end

  test "cannot change amount on an individual installment entry" do
    plan = EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 6, processing_fee: 0)
    installment = plan.installment_entries.first

    installment.amount = 1
    refute installment.valid?
    assert_includes installment.errors[:base], "Amount and date can't be changed on an individual EMI installment. Foreclose the plan to cancel remaining installments."
  end

  test "cannot change date on an individual installment entry" do
    plan = EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 6, processing_fee: 0)
    installment = plan.installment_entries.first

    installment.date = installment.date + 1.day
    refute installment.valid?
    assert_includes installment.errors[:base], "Amount and date can't be changed on an individual EMI installment. Foreclose the plan to cancel remaining installments."
  end

  test "processing fee entry amount and date can be edited freely" do
    plan = EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 6, processing_fee: 49)
    fee_entry = plan.processing_fee_entry

    fee_entry.amount = 55
    fee_entry.date = Date.current - 1.day
    assert fee_entry.valid?
  end

  test "bulk_update! skips date on emi purchase and installment entries instead of raising" do
    plan = EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 6, processing_fee: 0)
    installment = plan.installment_entries.first

    scope = Entry.where(id: [ @entry.id, installment.id ])
    assert_nothing_raised do
      scope.bulk_update!({ date: Date.current - 5.days, category_id: categories(:food_and_drink).id })
    end

    refute_equal Date.current - 5.days, @entry.reload.date
    refute_equal Date.current - 5.days, installment.reload.date
  end

  test "generated installment and fee entries are marked user_modified" do
    plan = EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 3, processing_fee: 10)

    assert plan.installment_entries.all?(&:user_modified?)
    assert plan.processing_fee_entry.user_modified?
  end

  test "rejects an interest rate above 100%" do
    assert_raises(ActiveRecord::RecordInvalid) do
      EmiPlan.build!(entry: @entry, interest_rate: 150, tenure_months: 6, processing_fee: 0)
    end
  end

  test "rejects a tenure beyond 480 months" do
    assert_raises(ActiveRecord::RecordInvalid) do
      EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 481, processing_fee: 0)
    end
  end

  test "rejects a negative or zero tenure" do
    assert_raises(ActiveRecord::RecordInvalid) do
      EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 0, processing_fee: 0)
    end

    assert_raises(ActiveRecord::RecordInvalid) do
      EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: -3, processing_fee: 0)
    end
  end

  test "rejects a start_date more than 5 years out in either direction" do
    assert_raises(ActiveRecord::RecordInvalid) do
      EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 6, processing_fee: 0, start_date: Date.current + 6.years)
    end

    assert_raises(ActiveRecord::RecordInvalid) do
      EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 6, processing_fee: 0, start_date: Date.current - 6.years)
    end
  end

  test "a malformed tenure_months param never creates any entries" do
    assert_no_difference "Entry.count" do
      assert_raises(ActiveRecord::RecordInvalid) do
        EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: "not-a-number", processing_fee: 0)
      end
    end
  end

  test "user cannot set an arbitrary principal_amount through build!" do
    # build! signature has no principal_amount param at all — principal is
    # always derived server-side from entry.amount.abs.
    plan = EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 6, processing_fee: 0)

    assert_equal @entry.amount.abs, plan.principal_amount
  end

  test "cannot directly change kind on an active emi_purchase transaction" do
    EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 6, processing_fee: 0)

    @entry.reload.transaction.kind = "standard"
    refute @entry.transaction.valid?
    assert_includes @entry.transaction.errors[:kind], "can't be changed while its EMI plan is active. Foreclose the plan first."
  end

  test "cannot directly change kind on an individual installment while its plan is active" do
    plan = EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 6, processing_fee: 0)
    installment = plan.installment_entries.first.transaction

    installment.kind = "standard"
    refute installment.valid?
    assert_includes installment.errors[:kind], "can't be changed while its EMI plan is active. Foreclose the plan first."
  end

  test "build! and foreclose! can still change kind themselves without the guard blocking them" do
    # These call the bypass (changing_emi_kind) internally -- this test just
    # confirms the normal lifecycle still works end-to-end with the new
    # validation in place, not that the bypass mechanics work in isolation.
    plan = EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 3, processing_fee: 0, start_date: Date.current + 1.month)
    assert_equal "emi_purchase", @entry.reload.transaction.kind

    plan.foreclose!
    assert_equal "standard", @entry.reload.transaction.kind
  end

  test "kind can be changed freely once foreclosed with nothing posted" do
    plan = EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 3, processing_fee: 0, start_date: Date.current + 1.month)
    plan.foreclose!

    @entry.reload.transaction.kind = "one_time"
    assert @entry.transaction.valid?
  end

  test "amount and date can be changed freely once foreclosed with nothing posted" do
    plan = EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 3, processing_fee: 0, start_date: Date.current + 1.month)
    plan.foreclose!

    entry = @entry.reload
    entry.amount = entry.amount + 50
    entry.date = Date.current - 1.day
    assert entry.valid?
  end

  test "amount and date stay locked once foreclosed if something already posted" do
    plan = EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 3, processing_fee: 0, start_date: Date.current - 1.month)
    plan.foreclose!

    entry = @entry.reload
    entry.amount = entry.amount + 50
    refute entry.valid?
    assert_includes entry.errors[:base], "Amount and date can't be changed on a purchase that's been converted to an EMI plan. Foreclose the plan first."
  end

  test "posted installment amount stays locked even after foreclose" do
    plan = EmiPlan.build!(entry: @entry, interest_rate: 0, tenure_months: 3, processing_fee: 0, start_date: Date.current - 1.month)
    posted = plan.posted_installments.first
    plan.foreclose!

    posted.reload.amount = 1
    refute posted.valid?
    assert_includes posted.errors[:base], "Amount and date can't be changed on an individual EMI installment. Foreclose the plan to cancel remaining installments."
  end
end
