require "test_helper"

class RecurringTransactions::SmartFillsControllerTest < ActionDispatch::IntegrationTest
  RawSuggestion = Provider::LlmConcept::BillSetupSuggestion

  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family = @user.family
    @entry = accounts(:depository).entries.create!(
      date: Date.current, amount: 40, currency: "USD", name: "GYM MEMBERSHIP",
      entryable: Transaction.new
    )
  end

  test "applies suggested values to the form and says so" do
    stub_provider(raw(name: "Gym Membership", amount: 42.0, frequency: "weekly", confidence: 0.9,
                      rationale: "Weekly gaps between charges"))

    post smart_fill_recurring_transactions_url(entry_id: @entry.id),
         headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_match I18n.t("recurring_transactions.new.smart_fill_applied"), response.body
    assert_match "Weekly gaps between charges", response.body
    assert_select "input[name=?][value=?]", "recurring_transaction[name]", "Gym Membership"
    assert_select "input[name=?][value=?]", "recurring_transaction[amount]", "42.00"
  end

  # Smart fill starts from the same prefill as the plain dialog, so the
  # transaction's category reaches the form here too.
  test "keeps the category of the transaction it starts from" do
    @entry.entryable.update!(category: categories(:food_and_drink))
    stub_provider(raw(name: "Gym Membership", amount: 42.0, frequency: "monthly", confidence: 0.9))

    post smart_fill_recurring_transactions_url(entry_id: @entry.id),
         headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_select "input[name=?][value=?]", "recurring_transaction[category_id]", categories(:food_and_drink).id
  end

  test "a provider failure keeps the plain prefill and explains" do
    provider = Object.new
    provider.define_singleton_method(:suggest_bill_setup) do |**|
      Provider::Response.new(success?: false, data: nil, error: StandardError.new("provider down"))
    end
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)

    post smart_fill_recurring_transactions_url(entry_id: @entry.id),
         headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_match "Could not analyze the charge history", response.body
    assert_select "input[name=?][value=?]", "recurring_transaction[name]", "GYM MEMBERSHIP",
      { count: 1 }, "the entry's own prefill must survive a failed suggestion"
  end

  test "forbidden without an LLM provider" do
    Provider::Registry.stubs(:preferred_llm_provider).returns(nil)

    post smart_fill_recurring_transactions_url(entry_id: @entry.id)

    assert_response :forbidden
  end

  test "forbidden without AI consent" do
    stub_provider(raw)
    @user.update!(ai_enabled: false)

    post smart_fill_recurring_transactions_url(entry_id: @entry.id)

    assert_response :forbidden
  end

  test "an inaccessible entry never becomes evidence" do
    stub_provider(raw(name: "Should not appear"))
    hidden = accounts(:investment).entries.create!(
      date: Date.current, amount: 30, currency: "USD", name: "PRIVATE FEE",
      entryable: Transaction.new
    )
    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
    sign_in member

    post smart_fill_recurring_transactions_url(entry_id: hidden.id),
         headers: { "Turbo-Frame" => "modal" }

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

    post smart_fill_recurring_transactions_url(entry_id: @entry.id),
         headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_match I18n.t("recurring_transactions.new.covered_title"), response.body
    assert_select "a[href=?]", bill_path(detected)
    assert_select "input[type=hidden][name=entry_id][value=?]", @entry.id
  end

  private

    def raw(**overrides)
      RawSuggestion.new(**{
        name: nil, amount: nil, frequency: nil, day_of_month: nil, weekday: nil,
        month_of_year: nil, category_name: nil, bill_type: nil, autopay: nil,
        confidence: nil, rationale: nil
      }.merge(overrides))
    end

    def stub_provider(suggestion)
      provider = Object.new
      provider.define_singleton_method(:suggest_bill_setup) do |**|
        Provider::Response.new(success?: true, data: suggestion, error: nil)
      end
      Provider::Registry.stubs(:preferred_llm_provider).returns(provider)
    end
end
