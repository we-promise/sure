require "test_helper"

class RecurringTransaction::AiSetupSuggesterTest < ActiveSupport::TestCase
  Suggester = RecurringTransaction::AiSetupSuggester
  RawSuggestion = Provider::LlmConcept::BillSetupSuggestion

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.recurring_transactions.destroy_all
    @entries = [ create_entry(name: "GYM MEMBERSHIP", amount: 40, date: Date.current) ]
  end

  test "raises when no LLM provider is configured" do
    Provider::Registry.stubs(:preferred_llm_provider).returns(nil)

    assert_raises(Suggester::Error) do
      Suggester.new(@family, user: @user).suggest_from_entries(@entries)
    end
  end

  test "raises on empty charge history instead of asking the model to guess" do
    stub_provider(raw(name: "X"))

    assert_raises(Suggester::Error) do
      Suggester.new(@family, user: @user).suggest_from_entries([])
    end
  end

  test "normalizes provider output: presets clamped, ranges enforced" do
    stub_provider(raw(
      name: "Gym", amount: 40.0, frequency: "fortnightly", day_of_month: 45,
      weekday: 9, month_of_year: 0, bill_type: "loan", confidence: 3.5
    ))

    suggestion = Suggester.new(@family, user: @user).suggest_from_entries(@entries)

    assert_nil suggestion.frequency, "an invented cadence must not survive"
    assert_nil suggestion.day_of_month
    assert_nil suggestion.weekday
    assert_nil suggestion.month_of_year
    assert_nil suggestion.bill_type
    assert_equal 1.0, suggestion.confidence, "confidence clamps into 0..1"
    assert_equal 40.0, suggestion.amount.to_f
  end

  test "an explicit autopay false survives normalization as a real proposal" do
    stub_provider(raw(autopay: false))

    suggestion = Suggester.new(@family, user: @user).suggest_from_entries(@entries)

    assert_equal false, suggestion.autopay, "false proposes turning autopay off; only nil means no proposal"
    assert suggestion.any_proposal?
  end

  test "a non-boolean autopay normalizes to no proposal" do
    stub_provider(raw(autopay: "yes"))

    suggestion = Suggester.new(@family, user: @user).suggest_from_entries(@entries)

    assert_nil suggestion.autopay
    assert_not suggestion.any_proposal?
  end

  test "resolves the category to this family's own id, case-insensitively" do
    category = @family.categories.create!(name: "Utilities", color: "#0000ff")
    stub_provider(raw(category_name: "utilities"))

    suggestion = Suggester.new(@family, user: @user).suggest_from_entries(@entries)

    assert_equal category.id, suggestion.category_id
    assert_equal "Utilities", suggestion.category_name
  end

  test "an LLM-invented category resolves to nothing" do
    stub_provider(raw(category_name: "Definitely Not A Real Category"))

    suggestion = Suggester.new(@family, user: @user).suggest_from_entries(@entries)

    assert_nil suggestion.category_id
    assert_nil suggestion.category_name
  end

  test "configure mode sends the series' current configuration to the provider" do
    series = @family.recurring_transactions.create!(
      name: "Gym", account: accounts(:depository), amount: 40, currency: "USD",
      expected_day_of_month: 9, anchor_date: Date.current,
      last_occurrence_date: 1.month.ago.to_date, next_expected_date: Date.current,
      status: "active", manual: true
    )
    # On the series' expected day: matching_transactions is day-of-month
    # scoped, so a drifting date would give the suggester no history.
    create_entry(name: "Gym", amount: 40, date: Date.current.beginning_of_month + 8.days - 1.month)

    captured = nil
    provider = Object.new
    provider.define_singleton_method(:suggest_bill_setup) do |**kwargs|
      captured = kwargs
      Provider::Response.new(success?: true, data: RawSuggestion.new(
        name: nil, amount: nil, frequency: nil, day_of_month: nil, weekday: nil,
        month_of_year: nil, category_name: nil, bill_type: nil, autopay: nil,
        confidence: 0.9, rationale: "already right"
      ), error: nil)
    end
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)

    suggestion = Suggester.new(@family, user: @user).suggest_configuration(series)

    assert_equal "Gym", captured[:current_config][:name]
    refute suggestion.any_proposal?, "all-null fields mean the configuration is already right"
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

    def create_entry(name:, amount:, date:)
      accounts(:depository).entries.create!(
        date: date, amount: amount, currency: "USD", name: name,
        entryable: Transaction.new
      )
    end
end
