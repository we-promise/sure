require "test_helper"

class RecurringTransaction::SuggestionTest < ActiveSupport::TestCase
  ai_capsule!
  include ActiveJob::TestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.recurring_transactions.destroy_all
    @entry = create_entry(name: "GYM MEMBERSHIP", amount: 40, date: Date.current)
    use_ai_routes
  end

  test "the job rechecks consent and fails with the router's reason" do
    stub_ai(:bill_setup, returns: raw(name: "Gym"))
    suggestion = fill_suggestion
    use_no_ai

    run_job(suggestion)

    assert suggestion.failed?
    assert_equal "not_configured", suggestion.error
  end

  test "a provider failure leaves a safe code and logs the detail" do
    stub_ai(:bill_setup, raises: Ai::Error::InvalidOutput.new("IBAN DE89 3704 0044 0532 0130 00"))
    suggestion = fill_suggestion

    run_job(suggestion)

    assert suggestion.failed?
    assert_equal "generation_failed", suggestion.error
    entry = DebugLogEntry.where(category: "bill_setup").last
    assert_includes entry.metadata["error_message"], "IBAN"
    assert_equal suggestion.id, entry.metadata["suggestion_id"]
  end

  test "only a pending suggestion records an answer or a failure" do
    stub_provider(raw(name: "Too late"))
    answer = fill_suggestion.ai_generation.call

    stopped = fill_suggestion
    stopped.update!(status: :cancelled)
    assert_equal 0, stopped.apply_ai(answer)
    stopped.ai_failed(StandardError.new("late failure"))
    stopped.ai_failed(Ai::Error::Cancelled.new("cancelled"))
    assert stopped.reload.cancelled?
    assert_nil stopped.result
    assert_nil stopped.error

    failed = fill_suggestion
    failed.update!(status: :failed, error: "already failed")
    assert_equal 0, failed.apply_ai(answer)
    assert_equal "already failed", failed.reload.error
    assert_nil failed.result

    pending = fill_suggestion
    pending.ai_failed(Ai::Error::Cancelled.new("cancelled"))
    assert pending.reload.pending?
    assert_nil pending.error
  end

  test "the answer is broadcast as a frame pointing at the stored result" do
    stub_provider(raw(name: "Gym"))
    suggestion = fill_suggestion
    answer = suggestion.ai_generation.call
    html = nil
    Turbo::StreamsChannel.expects(:broadcast_replace_to).with do |*args|
      options = args.last
      html = options[:html]
      args.first == suggestion && options[:target] == ActionView::RecordIdentifier.dom_id(suggestion)
    end

    suggestion.apply_ai(answer)

    assert_includes html, "src=\"/recurring_transactions/smart_fills/#{suggestion.id}\""
  end

  test "sends the charges and the family's categories through the bill_setup prompt" do
    requests = stub_ai(:bill_setup, returns: raw(name: "Gym"))

    complete_answer(fill_suggestion)

    assert_includes requests.first.input, "#{Date.current.iso8601} 40.0 GYM MEMBERSHIP"
    assert_includes requests.first.input, "AVAILABLE CATEGORIES: #{@family.categories.pluck(:name).join(", ")}"
    assert_not_includes requests.first.instructions, "A current configuration is provided"
  end

  test "configure mode raises rather than asking the model to guess with no history" do
    series = create_series(name: "Gym")
    stub_ai(:bill_setup, returns: raw(name: "X"))
    suggestion = configure_suggestion(series)

    error = assert_raises(RecurringTransaction::Suggestion::Error) { suggestion.ai_generation }
    assert_equal "No charge history to analyze", error.message
  end

  test "normalizes provider output: presets clamped, ranges enforced" do
    stub_provider(raw(
      name: "Gym", amount: 40.0, frequency: "fortnightly", day_of_month: 45,
      weekday: 9, month_of_year: 0, bill_type: "loan", confidence: 3.5
    ))

    answer = complete_answer(fill_suggestion)

    assert_nil answer.frequency, "an invented cadence must not survive"
    assert_nil answer.day_of_month
    assert_nil answer.weekday
    assert_nil answer.month_of_year
    assert_nil answer.bill_type
    assert_equal 1.0, answer.confidence, "confidence clamps into 0..1"
    assert_equal 40.0, answer.amount.to_f
  end

  test "autopay treats false as a proposal and other values as none" do
    stub_provider(raw(autopay: false))
    answer = complete_answer(fill_suggestion)
    assert_equal false, answer.autopay
    assert answer.any_proposal?

    stub_provider(raw(autopay: "yes"))
    answer = complete_answer(fill_suggestion)
    assert_nil answer.autopay
    assert_not answer.any_proposal?
  end

  test "categories resolve only to this family's own, case-insensitively" do
    category = @family.categories.create!(name: "Utilities", color: "#0000ff")
    stub_provider(raw(category_name: "utilities"))
    answer = complete_answer(fill_suggestion)
    assert_equal category.id, answer.category_id
    assert_equal "Utilities", answer.category_name

    stub_provider(raw(category_name: "Definitely Not A Real Category"))
    answer = complete_answer(fill_suggestion)
    assert_nil answer.category_id
    assert_nil answer.category_name
  end

  test "configure mode sends the series' current configuration" do
    series = create_series(name: "Gym")
    # On the series' expected day: matching_transactions is day-of-month scoped.
    create_entry(name: "Gym", amount: 40, date: Date.current.beginning_of_month + 8.days - 1.month)
    requests = stub_ai(:bill_setup, returns: raw(confidence: 0.9, rationale: "already right"))

    answer = complete_answer(configure_suggestion(series))
    assert_equal "Gym", current_config_sent(requests.first)["name"]
    assert_includes requests.first.instructions, "A current configuration is provided"
    refute answer.any_proposal?, "all-null fields mean the configuration is already right"

    interval = create_series(name: "Water", amount: 60)
    RecurringTransaction::FrequencyPreset.apply(interval, preset: "interval", interval: 2, interval_unit: "monthly",
                                                          day_of_month: 9)
    interval.save!
    create_entry(name: "Water", amount: 60, date: Date.current.beginning_of_month + 8.days - 2.months)
    requests = stub_ai(:bill_setup, returns: raw(confidence: 0.9, rationale: "already right"))

    complete_answer(configure_suggestion(interval))

    assert_equal "custom", current_config_sent(requests.first)["frequency"]
  end

  test "a one-off keeps the source entry's date instead of a monthly guess" do
    stub_provider(raw(name: "Gym", frequency: RecurringTransaction::FrequencyPreset::ONCE))
    suggestion = fill_suggestion
    series = @family.recurring_transactions.new(first_due_on: Date.current.next_month)

    complete_answer(suggestion)
    suggestion.apply_to(series)

    assert_equal @entry.date, series.first_due_on
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

    def fill_suggestion
      @family.recurring_transaction_suggestions.create!(user: @user, entry: @entry, mode: :fill)
    end

    def configure_suggestion(series)
      @family.recurring_transaction_suggestions.create!(user: @user, recurring_transaction: series, mode: :configure)
    end

    # The requester's answer, as the job applies it, without the job's retry policy.
    def complete_answer(suggestion)
      result = suggestion.ai_generation.call
      suggestion.apply_ai(result)
      suggestion.reload.proposal
    end

    def run_job(suggestion)
      perform_enqueued_jobs do
        Ai::GenerationJob.perform_later(:bill_setup, ai_run_args(:bill_setup, ids: [ suggestion.id ],
                                                                 family: @family, id: suggestion.id))
      end
      suggestion.reload
    end

    def current_config_sent(request) = JSON.parse(request.input.split("CURRENT CONFIGURATION:\n").last)

    def create_entry(name:, amount:, date:)
      accounts(:depository).entries.create!(
        date: date, amount: amount, currency: "USD", name: name,
        entryable: Transaction.new
      )
    end

    def create_series(name:, amount: 40)
      @family.recurring_transactions.create!(
        name: name, account: accounts(:depository), amount: amount, currency: "USD",
        expected_day_of_month: 9, anchor_date: Date.current,
        last_occurrence_date: 1.month.ago.to_date, next_expected_date: Date.current,
        status: "active", manual: true
      )
    end
end
