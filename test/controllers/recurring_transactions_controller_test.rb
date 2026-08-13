require "test_helper"

class RecurringTransactionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @recurring_transaction = recurring_transactions(:netflix_subscription)
    ensure_tailwind_build
  end

  test "edit renders the form" do
    get edit_recurring_transaction_url(@recurring_transaction)

    assert_response :success
  end

  # The dialog is delivered into the shared <turbo-frame id="modal"> that every page
  # layout already renders empty. If this action responds with a full page layout,
  # the response carries two frames with that id, Turbo matches the empty one first,
  # and the pencil icon silently does nothing. Assert there is exactly one.
  test "edit responds to a turbo frame request with a single modal frame" do
    get edit_recurring_transaction_url(@recurring_transaction),
        headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_equal 1, response.body.scan(/<turbo-frame[^>]*id="modal"/).size
  end

  test "a failed update still renders a single modal frame" do
    patch recurring_transaction_url(@recurring_transaction),
          params: { recurring_transaction: { payment_url: "javascript:alert(1)" } },
          headers: { "Turbo-Frame" => "modal" }

    assert_response :unprocessable_entity
    assert_equal 1, response.body.scan(/<turbo-frame[^>]*id="modal"/).size
  end

  test "update saves a payment link" do
    patch recurring_transaction_url(@recurring_transaction),
          params: { recurring_transaction: { payment_url: "pay.example.com/bill" } }

    assert_redirected_to recurring_transactions_url
    assert_equal "https://pay.example.com/bill", @recurring_transaction.reload.payment_url
  end

  test "new renders the create dialog in a single modal frame" do
    get new_recurring_transaction_url, headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_equal 1, response.body.scan(/<turbo-frame[^>]*id="modal"/).size
  end

  test "new prefills from a transaction" do
    entry = accounts(:depository).entries.create!(
      date: Date.current - 20, amount: 184.37, currency: "USD", name: "PG&E WEB PAYMENT",
      entryable: Transaction.new
    )

    get new_recurring_transaction_url(entry_id: entry.id), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_match "PG&amp;E WEB PAYMENT", response.body
    assert_match "184.37", response.body
  end

  test "create declares a manual bill and materializes its occurrences" do
    due = Date.current + 16

    assert_difference "@family.recurring_transactions.count", 1 do
      post recurring_transactions_url, params: {
        recurring_transaction: {
          name: "Watson Property",
          amount: "2150",
          account_id: accounts(:depository).id,
          first_due_on: due.iso8601,
          frequency_preset: "monthly"
        }
      }
    end

    bill = @family.recurring_transactions.order(:created_at).last
    assert bill.manual?
    assert_equal "active", bill.status
    assert_equal 2150, bill.amount
    assert_equal due.day, bill.expected_day_of_month
    assert_equal due, bill.anchor_date
    # Monthly on the derived day IS the zero-rule implicit shape, so no
    # redundant rule row is written; the detection reads it back correctly.
    detection = RecurringTransaction::FrequencyPreset.detect(bill)
    assert_equal "monthly", detection.key
    assert_equal due.day, detection.day_of_month
    assert bill.recurring_occurrences.reload.exists?(due_on: due),
           "the declared bill's occurrence must materialize immediately"
  end

  test "create with a non-monthly preset writes explicit rules" do
    due = Date.current + 4

    post recurring_transactions_url, params: {
      recurring_transaction: {
        name: "Cleaning service", amount: "80", account_id: accounts(:depository).id,
        first_due_on: due.iso8601, frequency_preset: "biweekly"
      }
    }

    bill = @family.recurring_transactions.order(:created_at).last
    rule = bill.recurrence_rules.sole
    assert_equal [ "weekly", 2, due.wday ], [ rule.frequency, rule.interval, rule.weekday ]
    assert_equal due, bill.anchor_date
  end

  test "create without a due date re-renders with an error" do
    assert_no_difference "@family.recurring_transactions.count" do
      post recurring_transactions_url, params: {
        recurring_transaction: { name: "No date", amount: "10", frequency_preset: "monthly", first_due_on: "" }
      }
    end

    assert_response :unprocessable_entity
  end

  test "create stamps dedup_scope when the identity is already taken" do
    post recurring_transactions_url, params: {
      recurring_transaction: { name: "STREAMCO", amount: "5.99", account_id: accounts(:depository).id,
                               first_due_on: (Date.current + 3).iso8601, frequency_preset: "monthly" }
    }
    post recurring_transactions_url, params: {
      recurring_transaction: { name: "STREAMCO", amount: "24.99", account_id: accounts(:depository).id,
                               first_due_on: (Date.current + 9).iso8601, frequency_preset: "monthly" }
    }

    tiers = @family.recurring_transactions.where(name: "STREAMCO").order(:amount)
    assert_equal 2, tiers.count
    assert_equal [ "", "24.99" ], tiers.map(&:dedup_scope)
  end

  test "marking a bill as an installment plan caps its occurrences and tracks progress" do
    due = Date.current + 5
    post recurring_transactions_url, params: {
      recurring_transaction: { name: "Klarna sofa", amount: "120", first_due_on: due.iso8601, frequency_preset: "monthly" }
    }
    bill = @family.recurring_transactions.find_by!(name: "Klarna sofa")

    patch recurring_transaction_url(bill), params: {
      recurring_transaction: { bill_type: "installment", end_after_count: "4" }
    }

    bill.reload
    assert bill.typed_installment?
    assert bill.ends_after_count?
    assert_equal 4, bill.recurring_occurrences.reload.count, "the plan materializes exactly its four payments"
    assert_equal [ 0, 4 ], bill.installment_progress

    occurrence = bill.recurring_occurrences.order(:due_on).first
    RecurringTransaction::Allocator.new(occurrence).mark_paid!
    assert_equal [ 1, 4 ], bill.reload.installment_progress
  end

  test "update applies a frequency preset as recurrence rules" do
    patch recurring_transaction_url(@recurring_transaction),
          params: { recurring_transaction: { frequency_preset: "biweekly", frequency_weekday: "5" } }

    assert_redirected_to recurring_transactions_url
    rules = @recurring_transaction.reload.recurrence_rules
    assert_equal [ [ "weekly", 2, 5 ] ], rules.map { |rule| [ rule.frequency, rule.interval, rule.weekday ] }
    assert_not_nil @recurring_transaction.anchor_date
  end

  test "update with an unchanged frequency does not rewrite the rules" do
    patch recurring_transaction_url(@recurring_transaction),
          params: { recurring_transaction: { frequency_preset: "weekly", frequency_weekday: "3" } }
    original_ids = @recurring_transaction.reload.recurrence_rules.map(&:id)

    patch recurring_transaction_url(@recurring_transaction),
          params: { recurring_transaction: { notes: "edited", frequency_preset: "weekly", frequency_weekday: "3" } }

    assert_equal original_ids, @recurring_transaction.reload.recurrence_rules.map(&:id)
    assert_equal "edited", @recurring_transaction.notes
  end

  test "update with an incomplete frequency re-renders the form" do
    patch recurring_transaction_url(@recurring_transaction),
          params: { recurring_transaction: { frequency_preset: "weekly" } },
          headers: { "Turbo-Frame" => "modal" }

    assert_response :unprocessable_entity
    assert_empty @recurring_transaction.reload.recurrence_rules
  end

  test "update rejects a non-http scheme instead of storing it" do
    patch recurring_transaction_url(@recurring_transaction),
          params: { recurring_transaction: { payment_url: "javascript:alert(1)" } }

    assert_response :unprocessable_entity
    assert_nil @recurring_transaction.reload.payment_url
  end

  test "update saves autopay and notes" do
    patch recurring_transaction_url(@recurring_transaction),
          params: { recurring_transaction: { autopay: "1", notes: "Account 4821" } }

    @recurring_transaction.reload
    assert @recurring_transaction.autopay?
    assert_equal "Account 4821", @recurring_transaction.notes
  end

  test "update can turn autopay back off" do
    @recurring_transaction.update!(autopay: true)

    patch recurring_transaction_url(@recurring_transaction),
          params: { recurring_transaction: { autopay: "0" } }

    assert_not @recurring_transaction.reload.autopay?
  end

  test "update clears the payment link when submitted blank" do
    @recurring_transaction.update!(payment_url: "https://pay.example.com")

    patch recurring_transaction_url(@recurring_transaction),
          params: { recurring_transaction: { payment_url: "" } }

    assert_nil @recurring_transaction.reload.payment_url
  end

  # One biller routinely owns several bills that all pay at one portal, so the link
  # can be fanned out on request. It must never reach a row outside the family.
  test "update copies the payment link to sibling bills of the same merchant when asked" do
    sibling = @family.recurring_transactions.create!(
      account: accounts(:depository),
      merchant: @recurring_transaction.merchant,
      amount: 4.99,
      dedup_scope: "4.99",
      currency: "USD",
      expected_day_of_month: 20,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date,
      status: "active"
    )
    other_merchant_bill = @family.recurring_transactions.create!(
      account: accounts(:depository),
      merchant: merchants(:amazon),
      amount: 7.99,
      currency: "USD",
      expected_day_of_month: 21,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date,
      status: "active"
    )

    patch recurring_transaction_url(@recurring_transaction),
          params: {
            recurring_transaction: { payment_url: "https://pay.example.com" },
            apply_to_siblings: "1"
          }

    assert_equal "https://pay.example.com", sibling.reload.payment_url
    assert_nil other_merchant_bill.reload.payment_url
  end

  # Auto-detection leaves merchant_id null whenever the provider feed gave it nothing
  # to match on, so most real bills are identified by name alone. Matching siblings on
  # merchant only would skip them entirely.
  test "update copies the payment link to name-matched siblings when there is no merchant" do
    named = @family.recurring_transactions.create!(
      account: accounts(:depository),
      name: "TWITCH",
      amount: 24.99,
      currency: "USD",
      expected_day_of_month: 21,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date,
      status: "active"
    )
    same_name = @family.recurring_transactions.create!(
      account: accounts(:depository),
      name: "TWITCH",
      amount: 5.99,
      dedup_scope: "5.99",
      currency: "USD",
      expected_day_of_month: 8,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date,
      status: "active"
    )
    different_name = @family.recurring_transactions.create!(
      account: accounts(:depository),
      name: "HUNTR.CO",
      amount: 40,
      currency: "USD",
      expected_day_of_month: 28,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date,
      status: "active"
    )

    patch recurring_transaction_url(named),
          params: {
            recurring_transaction: { payment_url: "https://twitch.tv/subscriptions" },
            apply_to_siblings: "1"
          }

    assert_equal "https://twitch.tv/subscriptions", same_name.reload.payment_url
    assert_nil different_name.reload.payment_url
    # A merchant-backed row must not be swept up by a name match.
    assert_nil @recurring_transaction.reload.payment_url
  end

  test "update does not touch siblings unless asked" do
    sibling = @family.recurring_transactions.create!(
      account: accounts(:depository),
      merchant: @recurring_transaction.merchant,
      amount: 4.99,
      dedup_scope: "4.99",
      currency: "USD",
      expected_day_of_month: 20,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date,
      status: "active"
    )

    patch recurring_transaction_url(@recurring_transaction),
          params: { recurring_transaction: { payment_url: "https://pay.example.com" } }

    assert_nil sibling.reload.payment_url
  end

  test "update cannot reach another family's recurring transaction" do
    other_family_recurring = families(:empty).recurring_transactions.create!(
      name: "Someone else's bill",
      amount: 10,
      currency: "USD",
      expected_day_of_month: 3,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date,
      status: "active"
    )

    patch recurring_transaction_url(other_family_recurring),
          params: { recurring_transaction: { payment_url: "https://evil.example.com" } }

    assert_response :not_found
    assert_nil other_family_recurring.reload.payment_url
  end
end
