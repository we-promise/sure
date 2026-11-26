require "test_helper"

class Bills::SmartConfigurationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family = @user.family
    use_ai_routes
    @family.recurring_transactions.destroy_all
    @series = @family.recurring_transactions.create!(
      name: "Gym", account: accounts(:depository), amount: 40, currency: "USD",
      expected_day_of_month: 9, anchor_date: Date.current,
      last_occurrence_date: Date.current.beginning_of_month + 8.days - 1.month,
      next_expected_date: Date.current.beginning_of_month + 8.days,
      status: "active", manual: true
    )
    accounts(:depository).entries.create!(
      date: Date.current.beginning_of_month + 8.days - 1.month, amount: 40,
      currency: "USD", name: "Gym", entryable: Transaction.new
    )
  end

  test "a request stores a pending suggestion, queues its job and shows a waiting frame" do
    assert_difference("RecurringTransaction::Suggestion.count", 1) do
      assert_enqueued_jobs 1, only: Ai::GenerationJob do
        post bill_smart_configurations_url(@series), headers: { "Turbo-Frame" => "modal" }
      end
    end

    suggestion = @family.recurring_transaction_suggestions.order(:created_at).last
    assert suggestion.pending?
    assert suggestion.configure?
    assert_equal @series, suggestion.recurring_transaction
    assert_response :success
    assert_match "Reading this bill", response.body
    assert_select "turbo-cable-stream-source"
    assert_select "form[action=?]", bill_smart_configuration_path(@series, suggestion)
    assert_select "input[name=_method][value=delete]"
  end

  test "a second request reuses the pending suggestion" do
    assert_enqueued_jobs 1, only: Ai::GenerationJob do
      post bill_smart_configurations_url(@series), headers: { "Turbo-Frame" => "modal" }
      post bill_smart_configurations_url(@series), headers: { "Turbo-Frame" => "modal" }
    end

    assert_equal 1, @family.recurring_transaction_suggestions.count
  end

  test "the stored answer is rendered as value-carrying checkboxes" do
    stub_provider(raw(amount: 45.0, frequency: "monthly", day_of_month: 9,
                      rationale: "Recent charges are 45"))

    suggestion = start_suggestion

    get bill_smart_configuration_url(@series, suggestion), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    # The checkbox IS the field: unchecked rows submit nothing.
    assert_select "input[type=checkbox][name=?][value=?]", "recurring_transaction[amount]", "45.0"
    assert_select "input[type=checkbox][name=?][value=?]", "recurring_transaction[frequency_preset]", "monthly"
    assert_select "form[action=?]", recurring_transaction_path(@series)
    assert_match "Recent charges are 45", response.body
  end

  test "an all-null answer means the bill is already right" do
    stub_provider(raw(confidence: 0.9))

    get bill_smart_configuration_url(@series, start_suggestion), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_match I18n.t("bills.smart_configurations.show.no_changes"), response.body
    assert_select "input[type=checkbox]", count: 0
  end

  test "checked proposals apply through the ordinary update path" do
    # Simulates submitting the dialog with only the amount box checked.
    patch recurring_transaction_url(@series), params: {
      recurring_transaction: { amount: "45.0" }
    }

    assert_equal 45.0, @series.reload.amount.to_f
  end

  test "Stop cancels a pending suggestion but leaves a finished answer alone" do
    suggestion = start_pending_suggestion

    assert_no_enqueued_jobs only: Ai::GenerationJob do
      delete bill_smart_configuration_url(@series, suggestion), headers: { "Turbo-Frame" => "modal" }
    end
    assert suggestion.reload.cancelled?
    assert_response :success
    assert_match I18n.t("bills.smart_configurations.show.stopped"), response.body
    assert_select "input[name=_method][value=delete]", count: 0

    stub_provider(raw(amount: 45.0))
    finished = start_suggestion
    result = finished.result
    delete bill_smart_configuration_url(@series, finished), headers: { "Turbo-Frame" => "modal" }

    assert_redirected_to bill_smart_configuration_path(@series, finished)
    assert_equal result, finished.reload.result
    assert finished.complete?
  end

  test "a suggestion whose job could not be queued is failed straight away" do
    Ai::GenerationRun.stubs(:enqueue).raises(StandardError, "queue down")

    post bill_smart_configurations_url(@series), headers: { "Turbo-Frame" => "modal" }

    suggestion = @family.recurring_transaction_suggestions.order(:created_at).last
    assert suggestion.failed?
    assert_equal "generation_failed", suggestion.error
    assert_match I18n.t("bills.smart_configurations.show.failed"), response.body
  end

  test "sent back with the reason when no model is set up for bills" do
    use_no_ai

    post bill_smart_configurations_url(@series)

    assert_redirected_to root_path
    assert_equal Ai::Availability.unavailable(:bill_setup, :not_configured).message_for(@user), flash[:alert]
  end

  test "show and stop stay reachable after the feature goes down" do
    suggestion = start_pending_suggestion
    use_no_ai

    get bill_smart_configuration_url(@series, suggestion), headers: { "Turbo-Frame" => "modal" }
    assert_response :success
    assert_match "Reading this bill", response.body

    delete bill_smart_configuration_url(@series, suggestion), headers: { "Turbo-Frame" => "modal" }
    assert_response :success
    assert suggestion.reload.cancelled?
  end

  test "another family's bill is not found" do
    other = families(:empty).recurring_transactions.create!(
      name: "Foreign", amount: 10, currency: "USD", expected_day_of_month: 1,
      last_occurrence_date: Date.current, next_expected_date: 1.month.from_now.to_date,
      status: "active"
    )

    post bill_smart_configurations_url(other)

    assert_response :not_found
  end

  test "another family's suggestion is not found" do
    suggestion = start_pending_suggestion
    outsider = users(:empty)
    outsider.update!(preferences: (outsider.preferences || {}).merge("preview_features_enabled" => true))
    sign_in outsider

    get bill_smart_configuration_url(@series, suggestion), headers: { "Turbo-Frame" => "modal" }

    assert_response :not_found
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

    def start_pending_suggestion
      post bill_smart_configurations_url(@series), headers: { "Turbo-Frame" => "modal" }
      @family.recurring_transaction_suggestions.where(status: :pending).order(:created_at).last
    end

    def start_suggestion
      suggestion = start_pending_suggestion
      perform_enqueued_jobs(only: Ai::GenerationJob)
      suggestion.reload
    end
end
