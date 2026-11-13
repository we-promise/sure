require "test_helper"
require "rake"

class RecurringDiagnoseRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("recurring:diagnose_reference")
    Rake::Task["recurring:diagnose_reference"].reenable
    @family = families(:dylan_family)
    @family.recurring_transactions.destroy_all
  end

  test "prints one line per payment carrying the reference and writes nothing" do
    account = accounts(:depository)
    @family.recurring_transactions.create!(
      name: "CITY WATER", account: account, amount: 80, currency: "USD", bill_type: "bill", expected_day_of_month: Date.current.day,
      anchor_date: Date.current, last_occurrence_date: Date.current, next_expected_date: Date.current, status: "active", manual: true,
      matcher_hints: { "bank_reference" => "VN 4711" }
    )
    account.entries.create!(date: Date.current, amount: 70, currency: "USD", name: "CITY WATER", notes: "VN 4711", entryable: Transaction.new)

    allocations = RecurringAllocation.count
    output, = capture_io { Rake::Task["recurring:diagnose_reference"].invoke("VN 4711", "6") }

    assert_match(/would link/, output)
    assert_equal allocations, RecurringAllocation.count
  end

  test "diagnose_series explains a transfer series without any reference" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("recurring:diagnose_series")
    Rake::Task["recurring:diagnose_series"].reenable
    account = accounts(:depository)
    @family.recurring_transactions.create!(
      name: "Allowance", account: account, destination_account: accounts(:loan), amount: 250, currency: "USD", bill_type: "transfer",
      expected_day_of_month: Date.current.day, anchor_date: Date.current, last_occurrence_date: Date.current,
      next_expected_date: Date.current, status: "active", manual: true
    )
    account.entries.create!(date: Date.current, amount: 250, currency: "USD", name: "plain", entryable: Transaction.new)

    output, = capture_io { Rake::Task["recurring:diagnose_series"].invoke("Allowance", "6") }

    assert_match(/not a transfer outflow/, output)
  end

  test "an unknown bill aborts with a message" do
    assert_raises(SystemExit) { capture_io { Rake::Task["recurring:diagnose_reference"].invoke("nope") } }
  end
end
