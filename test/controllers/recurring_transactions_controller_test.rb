require "test_helper"

class RecurringTransactionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    # The declare/edit/suggestion paths sit behind the Bills preview gate.
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family = @user.family
    @recurring_transaction = recurring_transactions(:netflix_subscription)
    ensure_tailwind_build
  end

  # How often is one of the four things anyone needs to add a bill, and it used
  # to render below the payment link and the autopay toggle: the fourth
  # essential field sat under two most people never set.
  test "the add form leads with the essentials and tucks the rest away" do
    get new_recurring_transaction_url, headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    body = response.body

    name_at = body.index("recurring_transaction[name]")
    amount_at = body.index("recurring_transaction[amount]")
    due_at = body.index("recurring_transaction[first_due_on]")
    often_at = body.index("recurring_transaction[frequency_preset]")
    url_at = body.index("recurring_transaction[payment_url]")

    assert name_at && amount_at && due_at && often_at && url_at
    assert_operator name_at, :<, amount_at
    assert_operator amount_at, :<, due_at
    assert_operator due_at, :<, often_at, "how often belongs with the essentials"
    assert_operator often_at, :<, url_at, "and above the advanced fields, not below them"

    # Tucked away is not the same as gone.
    assert_match "recurring_transaction[autopay]", body
    assert_match "recurring_transaction[notes]", body
    assert_match I18n.t("recurring_transactions.form.more_options"), body
  end

  test "edit renders the form" do
    get edit_recurring_transaction_url(@recurring_transaction)

    assert_response :success
  end

  # These three mutate: identify runs the whole detection and matching
  # pipeline, cleanup destroys stale series, and toggle_status pauses a bill,
  # which deletes its future occurrences. A GET route puts all of that behind a
  # plain URL, outside CSRF protection, where an image tag on any page a signed
  # in user visits is enough to fire it.
  test "the mutating actions refuse GET" do
    paths = {
      "/recurring_transactions/identify" => :get,
      "/recurring_transactions/cleanup" => :get,
      "/recurring_transactions/#{@recurring_transaction.id}/toggle_status" => :get
    }

    paths.each do |path, verb|
      assert_raises(ActionController::RoutingError, "#{path} must not answer #{verb.to_s.upcase}") do
        Rails.application.routes.recognize_path(path, method: verb)
      end
    end
  end

  test "identify runs the pipeline over POST" do
    post identify_recurring_transactions_url

    assert_redirected_to recurring_transactions_url
  end

  test "cleanup retires stale series over POST" do
    post cleanup_recurring_transactions_url

    assert_redirected_to recurring_transactions_url
  end

  test "toggle_status pauses and resumes over POST" do
    assert @recurring_transaction.active?

    post toggle_status_recurring_transaction_url(@recurring_transaction)
    assert_not @recurring_transaction.reload.active?

    post toggle_status_recurring_transaction_url(@recurring_transaction)
    assert @recurring_transaction.reload.active?
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

  test "add income opens an income dialog, not a bill dialog" do
    get new_recurring_transaction_url(income: true), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_match I18n.t("recurring_transactions.new.income_title"), response.body
    assert_match I18n.t("recurring_transactions.form.income_name_label"), response.body
    assert_match I18n.t("recurring_transactions.form.submit_income"), response.body
    # Nothing bill-shaped survives in income mode.
    assert_no_match I18n.t("recurring_transactions.form.autopay_hint"), response.body
    assert_no_match I18n.t("recurring_transactions.form.payment_url_label"), response.body
    assert_no_match I18n.t("recurring_transactions.form.submit"), response.body
  end

  test "fresh bill dialog offers detected recurring charges as starting points" do
    account = accounts(:depository)
    2.times do |i|
      account.entries.create!(
        date: Date.current - ((i + 1) * 30).days,
        amount: 45.00, currency: "USD", name: "City Water",
        entryable: Transaction.new
      )
    end

    get new_recurring_transaction_url, headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_match I18n.t("recurring_transactions.new.start_from_title"), response.body
    assert_match "City Water", response.body
  end

  test "the candidate strip never offers a pattern on an account the member cannot reach" do
    3.times do |i|
      accounts(:investment).entries.create!(
        date: Date.current - ((i + 1) * 30).days,
        amount: 45.00, currency: "USD", name: "PRIVATE BROKERAGE SUB",
        entryable: Transaction.new
      )
    end
    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
    sign_in member

    get new_recurring_transaction_url, headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_no_match "PRIVATE BROKERAGE SUB", response.body
  end

  test "income dialog offers only detected deposits" do
    account = accounts(:depository)
    2.times do |i|
      account.entries.create!(
        date: (i + 1).months.ago.beginning_of_month + 2.days,
        amount: -1840.00, currency: "USD", name: "ACME PAYROLL",
        entryable: Transaction.new
      )
      account.entries.create!(
        date: Date.current - ((i + 1) * 30).days,
        amount: 45.00, currency: "USD", name: "City Water",
        entryable: Transaction.new
      )
    end

    get new_recurring_transaction_url(income: true), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_match I18n.t("recurring_transactions.new.start_from_income_title"), response.body
    assert_match "ACME PAYROLL", response.body
    assert_no_match "City Water", response.body
  end

  test "prefilled dialog hides the picker" do
    account = accounts(:depository)
    entries = 2.times.map do |i|
      account.entries.create!(
        date: Date.current - ((i + 1) * 30).days,
        amount: 45.00, currency: "USD", name: "City Water",
        entryable: Transaction.new
      )
    end

    get new_recurring_transaction_url(entry_id: entries.last.id), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_no_match I18n.t("recurring_transactions.new.start_from_title"), response.body
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

  # Sharing is per account, so a family scope is not an access check. Prefilling
  # reads the entry's name, amount and account straight back into the form.
  test "new ignores a transaction from an account the user was never given" do
    hidden = accounts(:investment).entries.create!(
      date: Date.current - 3, amount: 622.41, currency: "USD", name: "PRIVATE BROKERAGE FEE",
      entryable: Transaction.new
    )
    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
    sign_in member

    get new_recurring_transaction_url(entry_id: hidden.id), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_no_match "PRIVATE BROKERAGE FEE", response.body
    assert_no_match "622.41", response.body
  end

  test "prefilling from an inflow pre-selects income" do
    entry = accounts(:depository).entries.create!(
      date: Date.current - 10, amount: -1840, currency: "USD", name: "ACME PAYROLL",
      entryable: Transaction.new
    )

    get new_recurring_transaction_url(entry_id: entry.id), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_match I18n.t("recurring_transactions.new.income_title"), response.body
  end

  test "editing income keeps bill wording out of the dialog" do
    payday = Date.current + 3
    income = @family.recurring_transactions.create!(
      name: "Paycheck", account: accounts(:depository), amount: -1840, currency: "USD",
      bill_type: "income", expected_day_of_month: payday.day, anchor_date: payday,
      last_occurrence_date: payday, next_expected_date: payday, status: "active", manual: true
    )

    get edit_recurring_transaction_url(income), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_match I18n.t("recurring_transactions.edit.income_title", name: "Paycheck"), response.body
    # Apostrophes HTML-escape in the body, so match on stable fragments.
    assert_match "match your payday", response.body
    assert_no_match(/comes due/, response.body)
  end

  test "removing a bill never touches the ledger and lands back on bills" do
    due = Date.current + 5
    bill = @family.recurring_transactions.create!(
      name: "City Water", account: accounts(:depository), amount: 45, currency: "USD",
      expected_day_of_month: due.day, anchor_date: due, last_occurrence_date: due,
      next_expected_date: due, status: "active", manual: true
    )
    RecurringTransaction::OccurrenceGenerator.new(bill).generate!
    entry = accounts(:depository).entries.create!(
      date: Date.current, amount: 45, currency: "USD", name: "CITY WATER",
      entryable: Transaction.new
    )
    occurrence = bill.recurring_occurrences.order(:due_on).first
    RecurringTransaction::Allocator.new(occurrence).allocate!(amount: "45", entry: entry)

    delete recurring_transaction_url(bill), headers: { "HTTP_REFERER" => bills_url }

    assert_redirected_to bills_url
    assert_equal I18n.t("recurring_transactions.deleted"), flash[:notice]
    assert Entry.exists?(entry.id), "removing a bill must never delete ledger entries"
  end

  # Which kind this is was settled by the entry point that opened the dialog.
  # The checkbox asked it again, and ticking it reshaped nothing: you filled in
  # bill-shaped labels, pressed Save bill, and got an income record.
  test "the add-bill dialog does not offer to make it income" do
    get new_recurring_transaction_url, headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_no_match(/name="recurring_transaction\[is_income\]"/, response.body)
  end

  test "the add-income dialog carries the answer without asking" do
    get new_recurring_transaction_url(income: true), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_match(/type="hidden"[^>]*name="recurring_transaction\[is_income\]"/, response.body)
    assert_no_match(/type="checkbox"[^>]*name="recurring_transaction\[is_income\]"/, response.body)
  end

  # Reported upstream: a deleted auto-detected recurring transaction comes back
  # on the next detection run, so users delete the same row over and over. The
  # pattern is still in the bank data, so a hard delete only lasts until the
  # next sync. Removing it leaves the same `ended` tombstone that dismissing a
  # suggestion does, and the Identifier refuses to claim or recreate one.
  test "a deleted detected bill does not come back on the next detection run" do
    account = accounts(:depository)
    anchor_day = Date.current.beginning_of_month + 8
    3.times do |i|
      account.entries.create!(
        date: anchor_day - i.months, amount: 42.00, currency: "USD",
        name: "City Water", entryable: Transaction.create!(category: categories(:food_and_drink))
      )
    end

    RecurringTransaction::Identifier.new(@family).identify_recurring_patterns
    detected = @family.recurring_transactions.find_by(name: "City Water")
    assert_not_nil detected
    assert_not detected.manual?

    delete recurring_transaction_url(detected)

    RecurringTransaction::Identifier.new(Family.find(@family.id)).identify_recurring_patterns

    rows = @family.recurring_transactions.where(name: "City Water")
    assert_equal 1, rows.count, "detection must not build a second row for a pattern the user removed"
    assert_equal "ended", rows.first.status, "and the one that remains is a tombstone, not a live bill"
    assert_empty @family.recurring_transactions.where(name: "City Water").where.not(status: "ended")
  end

  # A hand-declared bill has no pattern behind it, so nothing would bring it
  # back and it is deleted outright rather than left lying around as ended.
  test "a declared bill is deleted outright" do
    bill = @family.recurring_transactions.create!(
      name: "Typo Bill", account: accounts(:depository), amount: 10, currency: "USD",
      dedup_scope: "typo", bill_type: "bill", expected_day_of_month: Date.current.day,
      anchor_date: Date.current, last_occurrence_date: Date.current,
      next_expected_date: Date.current, status: "active", manual: true
    )

    assert_difference "@family.recurring_transactions.count", -1 do
      delete recurring_transaction_url(bill)
    end
  end

  test "creating income says income, not bill" do
    post recurring_transactions_url, params: {
      recurring_transaction: {
        name: "Paycheck",
        amount: "1840",
        account_id: accounts(:depository).id,
        first_due_on: (Date.current + 3).iso8601,
        frequency_preset: "biweekly",
        is_income: "1"
      }
    }

    assert_equal I18n.t("recurring_transactions.create.success_income"), flash[:notice]
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

  test "create with a currency-formatted amount re-renders with an error instead of crashing" do
    assert_no_difference "@family.recurring_transactions.count" do
      post recurring_transactions_url, params: {
        recurring_transaction: { name: "Trash Pickup", amount: "$40.00", account_id: accounts(:depository).id,
                                 first_due_on: (Date.current + 5).iso8601, frequency_preset: "monthly" }
      }
    end

    assert_response :unprocessable_entity
    assert_match I18n.t("recurring_transactions.create.amount_invalid"), response.body
  end

  test "update with an unresolvable account keeps the current account and reports the error" do
    original_account_id = @recurring_transaction.account_id

    patch recurring_transaction_url(@recurring_transaction),
          params: { recurring_transaction: { account_id: SecureRandom.uuid } }

    assert_response :unprocessable_entity
    assert_equal original_account_id, @recurring_transaction.reload.account_id,
      "a present-but-unresolvable id must not silently detach the account"
  end

  test "create stamps dedup_scope up front so tiers fork and true duplicates collide" do
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
    assert_equal [ "5.99", "24.99" ], tiers.map(&:dedup_scope)

    # The stamp makes the very first identical duplicate collide on insert.
    post recurring_transactions_url, params: {
      recurring_transaction: { name: "STREAMCO", amount: "5.99", account_id: accounts(:depository).id,
                               first_due_on: (Date.current + 3).iso8601, frequency_preset: "monthly" }
    }
    assert_equal 2, @family.recurring_transactions.where(name: "STREAMCO").count
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

  # A bill outliving its own price is the normal case. These used to be
  # create-only, so the only way to record a rise was delete-and-recreate,
  # which takes the occurrences and allocations with it.
  test "the edit dialog exposes name, amount and account" do
    series = recurring_transactions(:netflix_subscription)
    get edit_recurring_transaction_url(series)
    assert_response :success

    fields = response.body.scan(/name="recurring_transaction\[([a-z_]+)\]"/).flatten.uniq
    %w[name amount account_id].each do |field|
      assert_includes fields, field, "#{field} should be editable after creation"
    end
    refute_includes fields, "first_due_on",
      "first_due_on is inert on a persisted series; the frequency picker owns the schedule"
  end

  test "updating name, amount and account persists all three" do
    series = recurring_transactions(:netflix_subscription)
    other  = accounts(:credit_card)

    patch recurring_transaction_url(series), params: {
      recurring_transaction: { name: "Netflix Premium", amount: 24.99, account_id: other.id }
    }
    series.reload

    assert_equal "Netflix Premium", series.name
    assert_equal 24.99, series.amount.to_f
    assert_equal other.id, series.account_id
  end
  test "a bill cannot be pointed at an account the user cannot reach" do
    series = recurring_transactions(:netflix_subscription)
    foreign = families(:empty).accounts.create!(
      name: "Someone else's checking", balance: 0, currency: "USD",
      accountable: Depository.new
    )
    refute_equal series.family_id, foreign.family_id

    patch recurring_transaction_url(series), params: {
      recurring_transaction: { account_id: foreign.id }
    }

    refute_equal foreign.id, series.reload.account_id,
      "a crafted account_id must not reach another family's account"
  end

  test "editing an income series keeps its negative sign" do
    income = recurring_transactions(:netflix_subscription)
    income.update!(bill_type: "income", amount: -2000)

    patch recurring_transaction_url(income), params: {
      recurring_transaction: { amount: 2500 }
    }

    assert_equal(-2500, income.reload.amount.to_f,
      "income is stored negative; a raw assignment would flip it into a bill")
  end

  test "the edit form shows an income amount as a positive magnitude" do
    income = recurring_transactions(:netflix_subscription)
    income.update!(bill_type: "income", amount: -2000)

    get edit_recurring_transaction_url(income)

    assert_response :success
    # The stored sign is bookkeeping; the form edits what the paycheck pays.
    assert_select "input[name=?][value=?]", "recurring_transaction[amount]", "2000.0"
  end

  test "the edit form shows a bill amount as it is stored" do
    get edit_recurring_transaction_url(recurring_transactions(:netflix_subscription))

    assert_response :success
    assert_select "input[name=?][value=?]", "recurring_transaction[amount]", "15.99"
  end
  # Detected bills carry a merchant and no name of their own. The field has to
  # arrive seeded, or it renders empty and, being required, browsers refuse to
  # submit the whole form; and the rename has to actually show, or it is a
  # control that silently does nothing.
  test "renaming a detected bill seeds the field and takes effect" do
    series = recurring_transactions(:netflix_subscription)
    assert series.name.blank?, "premise: this bill is named by its merchant"
    assert series.merchant.present?

    get edit_recurring_transaction_url(series)
    assert_select "input[name=?][value=?]", "recurring_transaction[name]", series.display_name

    patch recurring_transaction_url(series), params: {
      recurring_transaction: { name: "Netflix Premium" }
    }

    assert_equal "Netflix Premium", series.reload.display_name,
      "a name the user typed should win over the detected merchant"
  end

  # --- Suggested-series review: confirm/dismiss from either page ---

  test "confirming from the Bills page returns there and reconstructs the bill's history" do
    last_month_ninth = Date.current.beginning_of_month + 8.days - 1.month
    suggestion = @family.recurring_transactions.create!(
      name: "CITY WATER", account: accounts(:depository), amount: 80, currency: "USD",
      expected_day_of_month: 9, last_occurrence_date: last_month_ninth,
      next_expected_date: last_month_ninth + 1.month, status: "suggested", manual: false
    )
    accounts(:depository).entries.create!(
      date: last_month_ninth, amount: 80, currency: "USD", name: "CITY WATER",
      entryable: Transaction.new
    )

    post confirm_recurring_transaction_url(suggestion), headers: { "HTTP_REFERER" => bills_url }

    assert_redirected_to bills_url
    assert suggestion.reload.active?
    assert_operator suggestion.recurring_occurrences.count, :>, 0,
      "confirming must materialize the schedule"
    assert suggestion.recurring_occurrences.paid.where(due_on: last_month_ninth).exists?,
      "confirming must close history a real entry anchors"
  end

  test "confirming twice does not double anything" do
    suggestion = @family.recurring_transactions.create!(
      name: "CITY GAS", account: accounts(:depository), amount: 55, currency: "USD",
      expected_day_of_month: 9,
      last_occurrence_date: Date.current.beginning_of_month + 8.days - 1.month,
      next_expected_date: Date.current.beginning_of_month + 8.days,
      status: "suggested", manual: false
    )

    post confirm_recurring_transaction_url(suggestion)
    state = suggestion.recurring_occurrences.order(:due_on).pluck(:due_on, :status)

    post confirm_recurring_transaction_url(suggestion)

    assert_equal state, suggestion.recurring_occurrences.order(:due_on).pluck(:due_on, :status)
  end

  test "dismissing from the Bills page tombstones and returns there" do
    suggestion = @family.recurring_transactions.create!(
      name: "PHANTOM SUB", account: accounts(:depository), amount: 12, currency: "USD",
      expected_day_of_month: 5, last_occurrence_date: 1.month.ago.to_date,
      next_expected_date: Date.current, status: "suggested", manual: false
    )

    post dismiss_recurring_transaction_url(suggestion), headers: { "HTTP_REFERER" => bills_url }

    assert_redirected_to bills_url
    assert suggestion.reload.ended?
  end

  # --- "Search all your transactions" picker inside the add dialog ---

  test "the add dialog links to the picker whether or not detection found anything" do
    get new_recurring_transaction_url, headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_match I18n.t("recurring_transactions.new.search_all_cta"), response.body
    assert_select "a[href=?]", new_recurring_transaction_path(picker: 1)
  end

  test "picker lists recent outflows as prefill links" do
    entry = picker_entry(name: "ACME POWER", amount: 120)

    get new_recurring_transaction_url(picker: 1), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_match "ACME POWER", response.body
    assert_select "a[href=?]", new_recurring_transaction_path(entry_id: entry.id)
  end

  test "picker filters by sign in each mode" do
    picker_entry(name: "PAYCHECK DEPOSIT", amount: -900)
    picker_entry(name: "ACME POWER", amount: 120)

    get new_recurring_transaction_url(picker: 1), headers: { "Turbo-Frame" => "modal" }
    assert_match "ACME POWER", response.body
    assert_no_match "PAYCHECK DEPOSIT", response.body

    get new_recurring_transaction_url(picker: 1, income: 1), headers: { "Turbo-Frame" => "modal" }
    assert_match "PAYCHECK DEPOSIT", response.body
    assert_no_match "ACME POWER", response.body
  end

  test "picker search matches the merchant behind a bank-blob entry name" do
    picker_entry(name: "ACH WEB PMT 0042", amount: 15.49, merchant: merchants(:netflix))
    picker_entry(name: "UNRELATED CHARGE", amount: 8)

    get new_recurring_transaction_url(picker: 1, q: merchants(:netflix).name),
        headers: { "Turbo-Frame" => "modal" }

    assert_match "ACH WEB PMT 0042", response.body
    assert_no_match "UNRELATED CHARGE", response.body
  end

  test "picker search matches notes" do
    picker_entry(name: "CHECK 1042", amount: 300, notes: "quarterly water bill")
    picker_entry(name: "CHECK 1043", amount: 300)

    get new_recurring_transaction_url(picker: 1, q: "quarterly water"),
        headers: { "Turbo-Frame" => "modal" }

    assert_match "CHECK 1042", response.body
    assert_no_match "CHECK 1043", response.body
  end

  test "picker search treats LIKE metacharacters as literals" do
    picker_entry(name: "100% Juice Co", amount: 6)
    picker_entry(name: "1003 Deli", amount: 9)

    get new_recurring_transaction_url(picker: 1, q: "100%"), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_match "100% Juice Co", response.body
    assert_no_match "1003 Deli", response.body
  end

  test "picker hides transfers and excluded entries" do
    picker_entry(name: "CARD PAYMENT", amount: 200, kind: "cc_payment")
    picker_entry(name: "HIDDEN CHARGE", amount: 25, excluded: true)
    picker_entry(name: "REAL CHARGE", amount: 25)

    get new_recurring_transaction_url(picker: 1), headers: { "Turbo-Frame" => "modal" }

    assert_match "REAL CHARGE", response.body
    assert_no_match "CARD PAYMENT", response.body
    assert_no_match "HIDDEN CHARGE", response.body
  end

  test "picker never shows an account the member was not given, even on exact match" do
    hidden = picker_entry(name: "PRIVATE BROKERAGE FEE", amount: 30, account: accounts(:investment))
    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
    sign_in member

    get new_recurring_transaction_url(picker: 1, q: "PRIVATE BROKERAGE FEE"),
        headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    # The no-results copy echoes the query, so assert on the row link itself.
    assert_select "a[href=?]", new_recurring_transaction_path(entry_id: hidden.id), count: 0
    assert_match I18n.t("recurring_transactions.pick_entry.back"), response.body
  end

  test "an entry already backing a bill carries a chip instead of being hidden" do
    claimed = picker_entry(name: "NETFLIX.COM", amount: 15.99)
    series = @family.recurring_transactions.create!(
      name: "Netflix", account: accounts(:depository), amount: 15.99, currency: "USD",
      dedup_scope: "chip", expected_day_of_month: Date.current.day,
      last_occurrence_date: 1.month.ago.to_date, next_expected_date: Date.current,
      status: "active", manual: true
    )
    occurrence = series.recurring_occurrences.order(:due_on).first
    occurrence.allocations.create!(
      entry: claimed, allocated_amount: 15.99, currency: "USD", source: "user_created"
    )
    picker_entry(name: "UNCLAIMED CHARGE", amount: 12)

    get new_recurring_transaction_url(picker: 1), headers: { "Turbo-Frame" => "modal" }

    assert_match I18n.t("recurring_transactions.picker_row.claimed", name: "Netflix"), response.body
    # The chip names its bill once, on the claimed row only.
    assert_equal 1, response.body.scan(
      I18n.t("recurring_transactions.picker_row.claimed", name: "Netflix")
    ).size
  end

  test "picker caps at twenty rows and says so" do
    25.times { |i| picker_entry(name: "CHARGE #{format('%02d', i)}", amount: 5 + i) }

    get new_recurring_transaction_url(picker: 1), headers: { "Turbo-Frame" => "modal" }

    assert_equal RecurringTransactionsController::PICKER_SHOWN,
      response.body.scan(/CHARGE \d\d/).uniq.size
    assert_match I18n.t("recurring_transactions.pick_entry.showing_recent",
      count: RecurringTransactionsController::PICKER_SHOWN), response.body
  end

  test "picker with no results explains and offers the way back" do
    get new_recurring_transaction_url(picker: 1, q: "zzz-nothing-matches"),
        headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_match CGI.escapeHTML("zzz-nothing-matches"), response.body
    assert_match I18n.t("recurring_transactions.pick_entry.back"), response.body
  end

  # The declare, edit and suggestion paths shipped with Bills, so they honor
  # the same preview gate as every other Bills surface. Direct URLs included:
  # the gate is a before_action, not a matter of which buttons render.
  test "the bills-era actions sit behind the preview gate" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get new_recurring_transaction_url
    assert_redirected_to root_path

    assert_no_difference "RecurringTransaction.count" do
      post recurring_transactions_url, params: { recurring_transaction: {
        name: "Gated", amount: 10, first_due_on: Date.current.iso8601, frequency_preset: "monthly"
      } }
    end
    assert_redirected_to root_path

    original_name = @recurring_transaction.name
    patch recurring_transaction_url(@recurring_transaction), params: { recurring_transaction: { name: "Renamed" } }
    assert_redirected_to root_path
    assert_equal original_name, @recurring_transaction.reload.name

    suggestion = create_series(name: "Maybe A Bill", status: "suggested")
    post confirm_recurring_transaction_url(suggestion)
    assert_redirected_to root_path
    assert suggestion.reload.suggested?
  end

  test "the pre-bills settings actions stay reachable without the preview flag" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get recurring_transactions_url
    assert_response :success

    post toggle_status_recurring_transaction_url(@recurring_transaction)
    assert_redirected_to recurring_transactions_url
  end

  # Sharing is per account: a read-only share may SEE the series everywhere the
  # app lists it, and must not be able to change or remove it. Mirrors
  # RecurringOccurrencesController#ensure_series_writable.
  test "a read-only account share can see but not mutate a series" do
    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
    # The credit card fixture is shared with the member read_only.
    series = create_series(name: "Shared Read Only", account: accounts(:credit_card))
    suggestion = create_series(name: "Shared Suggestion", account: accounts(:credit_card), status: "suggested")

    sign_in member

    # Visible: the read dialog opens. The write guard bites only on mutation.
    get edit_recurring_transaction_url(series), headers: { "Turbo-Frame" => "modal" }
    assert_response :success
    assert_match "Shared Read Only", response.body

    patch recurring_transaction_url(series), params: { recurring_transaction: { name: "Hijacked" } }
    assert_response :not_found
    assert_equal "Shared Read Only", series.reload.name

    post toggle_status_recurring_transaction_url(series)
    assert_response :not_found
    assert series.reload.active?

    post confirm_recurring_transaction_url(suggestion)
    assert_response :not_found
    assert suggestion.reload.suggested?

    post dismiss_recurring_transaction_url(suggestion)
    assert_response :not_found
    assert suggestion.reload.suggested?

    delete recurring_transaction_url(series)
    assert_response :not_found
    assert series.reload.persisted?
  end

  test "an accountless series carries no account write gate" do
    series = create_series(name: "No Account", account: nil)

    patch recurring_transaction_url(series), params: { recurring_transaction: { name: "Renamed Fine" } }

    assert_response :redirect
    assert_equal "Renamed Fine", series.reload.name
  end

  # The destination is a write too: attaching a series to an account changes
  # what that account's owners see, so a read-only share cannot receive one,
  # whether by edit or at declaration.
  test "a read-only account cannot become a series' destination" do
    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
    series = create_series(name: "Wandering Bill", account: nil)

    sign_in member

    patch recurring_transaction_url(series), params: { recurring_transaction: { account_id: accounts(:credit_card).id } }
    assert_response :unprocessable_entity
    assert_nil series.reload.account_id

    assert_no_difference "RecurringTransaction.count" do
      post recurring_transactions_url, params: { recurring_transaction: {
        name: "Declared On Read Only", amount: 12, first_due_on: Date.current.iso8601,
        frequency_preset: "monthly", account_id: accounts(:credit_card).id
      } }
    end
    assert_response :unprocessable_entity
    assert_match I18n.t("recurring_transactions.create.account_invalid"), response.body
  end

  # Clearing a payment link is a statement about one bill; the opt-in copy
  # must not blank the siblings' own links on the way through.
  test "clearing the payment link never blanks the siblings" do
    source = create_series(name: "Twitch Tier 1", merchant: merchants(:netflix), payment_url: "https://pay.example/1")
    sibling = create_series(name: "Twitch Tier 2", merchant: merchants(:netflix), payment_url: "https://pay.example/keep")

    patch recurring_transaction_url(source), params: {
      apply_to_siblings: "1",
      recurring_transaction: { payment_url: "" }
    }

    assert_response :redirect
    assert_nil source.reload.payment_url.presence
    assert_equal "https://pay.example/keep", sibling.reload.payment_url
  end

  test "the sibling copy skips series on accounts the user cannot write" do
    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))

    source = create_series(name: "Portal Bill", account: nil, merchant: merchants(:netflix))
    # The credit card fixture is shared with the member read_only: visible,
    # therefore inside accessible_by, and exactly what the copy must skip.
    read_only_sibling = create_series(name: "Portal Bill RO", account: accounts(:credit_card),
                                      merchant: merchants(:netflix), payment_url: "https://pay.example/theirs")

    sign_in member
    patch recurring_transaction_url(source), params: {
      apply_to_siblings: "1",
      recurring_transaction: { payment_url: "https://pay.example/mine" }
    }

    assert_response :redirect
    assert_equal "https://pay.example/mine", source.reload.payment_url
    assert_equal "https://pay.example/theirs", read_only_sibling.reload.payment_url
  end

  private

    def create_series(name:, account: accounts(:depository), merchant: nil, status: "active", payment_url: nil)
      @family.recurring_transactions.create!(
        account: account,
        merchant: merchant,
        name: name,
        amount: 25,
        dedup_scope: name,
        currency: "USD",
        expected_day_of_month: 5,
        last_occurrence_date: 1.month.ago.to_date,
        next_expected_date: 5.days.from_now.to_date,
        status: status,
        payment_url: payment_url
      )
    end

    def picker_entry(name:, amount:, account: accounts(:depository), merchant: nil, notes: nil, kind: nil, excluded: false)
      transaction_attrs = { merchant: merchant }
      transaction_attrs[:kind] = kind if kind

      account.entries.create!(
        date: Date.current, amount: amount, currency: "USD", name: name,
        notes: notes, excluded: excluded,
        entryable: Transaction.new(**transaction_attrs)
      )
    end
end
