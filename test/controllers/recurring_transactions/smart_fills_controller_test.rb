require "test_helper"

class RecurringTransactions::SmartFillsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family = @user.family
    use_ai_routes
    @entry = accounts(:depository).entries.create!(
      date: Date.current, amount: 40, currency: "USD", name: "GYM MEMBERSHIP",
      entryable: Transaction.new
    )
  end

  test "a request stores a pending suggestion, queues its job and shows a waiting frame" do
    assert_difference("RecurringTransaction::Suggestion.count", 1) do
      assert_enqueued_jobs 1, only: Ai::GenerationJob do
        post recurring_transactions_smart_fills_url(entry_id: @entry.id), headers: { "Turbo-Frame" => "modal" }
      end
    end

    suggestion = RecurringTransaction::Suggestion.last
    assert suggestion.pending?
    assert suggestion.fill?
    assert_equal @entry, suggestion.entry
    assert_response :success
    assert_match "Reading this charge", response.body
    assert_select "turbo-cable-stream-source"
    assert_select "form[action=?]", recurring_transactions_smart_fill_path(suggestion)
    assert_select "input[name=_method][value=delete]"
  end

  test "a second request reuses the pending suggestion" do
    assert_enqueued_jobs 1, only: Ai::GenerationJob do
      post recurring_transactions_smart_fills_url(entry_id: @entry.id), headers: { "Turbo-Frame" => "modal" }
      post recurring_transactions_smart_fills_url(entry_id: @entry.id), headers: { "Turbo-Frame" => "modal" }
    end

    assert_equal 1, @family.recurring_transaction_suggestions.count
  end

  test "the stored answer is rendered on show with the suggested values in the form" do
    stub_provider(raw(name: "Gym Membership", amount: 42.0, frequency: "weekly", confidence: 0.9,
                      rationale: "Weekly gaps between charges"))

    suggestion = start_suggestion
    assert_equal "complete", suggestion.status

    get recurring_transactions_smart_fill_url(suggestion), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_match I18n.t("recurring_transactions.new.smart_fill_applied"), response.body
    assert_match "Weekly gaps between charges", response.body
    assert_select "input[name=?][value=?]", "recurring_transaction[name]", "Gym Membership"
    assert_select "input[name=?][value=?]", "recurring_transaction[amount]", "42.00"
  end

  test "a one-off answer keeps the date of the charge it was read from" do
    charged_on = 20.days.ago.to_date
    entry = accounts(:depository).entries.create!(
      date: charged_on, amount: 320, currency: "USD", name: "CAR REGISTRATION", entryable: Transaction.new
    )
    stub_provider(raw(name: "Car registration", amount: 320.0, frequency: "once", confidence: 0.8))

    get recurring_transactions_smart_fill_url(start_suggestion(entry:)), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_select "input[name=?][value=?]", "recurring_transaction[first_due_on]", charged_on.iso8601
  end

  test "the category of the source transaction survives an answer that proposes none" do
    @entry.entryable.update!(category: categories(:food_and_drink))
    stub_provider(raw(name: "Gym Membership", amount: 42.0, frequency: "monthly", confidence: 0.9))

    get recurring_transactions_smart_fill_url(start_suggestion), headers: { "Turbo-Frame" => "modal" }

    assert_select "input[name=?][value=?]", "recurring_transaction[category_id]", categories(:food_and_drink).id
  end

  test "a provider failure leaves the plain prefill and explains on show" do
    stub_ai(:bill_setup, raises: Ai::Error::InvalidOutput.new("no JSON"))

    suggestion = start_suggestion
    assert suggestion.failed?

    get recurring_transactions_smart_fill_url(suggestion), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_match "Could not analyze this charge", response.body
    assert_select "input[name=?][value=?]", "recurring_transaction[name]", "GYM MEMBERSHIP",
      { count: 1 }, "the entry's own prefill must survive a failed suggestion"
  end

  test "an inaccessible entry never becomes evidence" do
    stub_provider(raw(name: "Should not appear"))
    hidden = accounts(:investment).entries.create!(
      date: Date.current, amount: 30, currency: "USD", name: "PRIVATE FEE", entryable: Transaction.new
    )
    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
    sign_in member

    assert_no_enqueued_jobs only: Ai::GenerationJob do
      post recurring_transactions_smart_fills_url(entry_id: hidden.id), headers: { "Turbo-Frame" => "modal" }
    end

    assert_response :success
    assert_match "Could not analyze the charge history", response.body
    assert_no_match "Should not appear", response.body
  end

  test "smart fill on a transaction a bill already covers still warns" do
    detected = @family.recurring_transactions.create!(
      account: accounts(:depository), name: "GYM MEMBERSHIP", amount: 40, currency: "USD",
      expected_day_of_month: Date.current.day, last_occurrence_date: 1.month.ago.to_date,
      next_expected_date: Date.current, status: "active", manual: false, occurrence_count: 2
    )
    stub_provider(raw(name: "Gym Membership", amount: 40.0, frequency: "monthly", confidence: 0.9))

    get recurring_transactions_smart_fill_url(start_suggestion), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_match I18n.t("recurring_transactions.new.covered_title"), response.body
    assert_select "a[href=?]", bill_path(detected)
    assert_select "input[type=hidden][name=entry_id][value=?]", @entry.id
  end

  test "Stop cancels the pending suggestion and removes the waiting state" do
    suggestion = start_pending_suggestion

    assert_no_enqueued_jobs only: Ai::GenerationJob do
      delete recurring_transactions_smart_fill_url(suggestion), headers: { "Turbo-Frame" => "modal" }
    end

    assert suggestion.reload.cancelled?
    assert_response :success
    assert_match "Stopped", response.body
    assert_select "input[name=_method][value=delete]", count: 0
  end

  test "a job that finishes after Stop leaves the cancelled suggestion alone" do
    stub_provider(raw(name: "Too late"))
    suggestion = start_pending_suggestion

    delete recurring_transactions_smart_fill_url(suggestion), headers: { "Turbo-Frame" => "modal" }
    perform_enqueued_jobs(only: Ai::GenerationJob)

    assert suggestion.reload.cancelled?
    assert_nil suggestion.result
    assert_nil suggestion.error
  end

  test "Stop on a finished suggestion changes nothing and reloads show" do
    stub_provider(raw(name: "Gym Membership"))
    suggestion = start_suggestion
    result = suggestion.result

    delete recurring_transactions_smart_fill_url(suggestion), headers: { "Turbo-Frame" => "modal" }

    assert_redirected_to recurring_transactions_smart_fill_path(suggestion)
    assert_equal result, suggestion.reload.result
    assert suggestion.complete?
  end

  test "a suggestion whose job could not be queued is failed straight away" do
    Ai::GenerationRun.stubs(:enqueue).raises(StandardError, "queue down")

    post recurring_transactions_smart_fills_url(entry_id: @entry.id), headers: { "Turbo-Frame" => "modal" }

    suggestion = RecurringTransaction::Suggestion.last
    assert suggestion.failed?
    assert_equal I18n.t("recurring_transactions.smart_fills.create.failed"), suggestion.error
    assert_match "Could not analyze this charge", response.body
  end

  test "sent back with the reason when no model is set up for bills" do
    use_no_ai

    post recurring_transactions_smart_fills_url(entry_id: @entry.id)

    assert_redirected_to root_path
    assert_equal Ai::Availability.unavailable(:bill_setup, :not_configured).message_for(@user), flash[:alert]
  end

  test "show is guarded too" do
    suggestion = start_pending_suggestion
    use_no_ai

    get recurring_transactions_smart_fill_url(suggestion)

    assert_redirected_to root_path
  end

  test "stop is guarded too" do
    suggestion = start_pending_suggestion
    use_no_ai

    delete recurring_transactions_smart_fill_url(suggestion)

    assert_redirected_to root_path
    assert suggestion.reload.pending?
  end

  test "sent back without the user's AI switch" do
    @user.update!(ai_enabled: false)

    post recurring_transactions_smart_fills_url(entry_id: @entry.id)

    assert_redirected_to root_path
    assert_equal Ai::Availability.unavailable(:bill_setup, :user_disabled).message_for(@user), flash[:alert]
  end

  test "a JSON request gets the reason" do
    use_no_ai

    post recurring_transactions_smart_fills_url(entry_id: @entry.id, format: :json)

    assert_response :forbidden
    assert_equal({ "error" => "ai_unavailable", "reason" => "not_configured" }, response.parsed_body)
  end

  private

    def raw(**overrides)
      {
        name: nil, amount: nil, frequency: nil, day_of_month: nil, weekday: nil,
        month_of_year: nil, category_name: nil, bill_type: nil, autopay: nil,
        confidence: nil, rationale: nil
      }.merge(overrides)
    end

    def stub_provider(suggestion) = stub_ai(:bill_setup, returns: suggestion)

    def start_pending_suggestion(entry: @entry)
      post recurring_transactions_smart_fills_url(entry_id: entry.id), headers: { "Turbo-Frame" => "modal" }
      RecurringTransaction::Suggestion.last
    end

    # The controller starts the request, then the job stores the answer: exactly
    # what the browser does when the broadcast reloads the waiting frame.
    def start_suggestion(entry: @entry)
      suggestion = start_pending_suggestion(entry:)
      perform_enqueued_jobs(only: Ai::GenerationJob)
      suggestion.reload
    end
end
