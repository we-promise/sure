require "test_helper"

class Bills::SmartConfigurationsControllerTest < ActionDispatch::IntegrationTest
  RawSuggestion = Provider::LlmConcept::BillSetupSuggestion

  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family = @user.family
    @family.recurring_transactions.destroy_all
    @series = @family.recurring_transactions.create!(
      name: "Gym", account: accounts(:depository), amount: 40, currency: "USD",
      expected_day_of_month: 9, anchor_date: Date.current,
      last_occurrence_date: Date.current.beginning_of_month + 8.days - 1.month,
      next_expected_date: Date.current.beginning_of_month + 8.days,
      status: "active", manual: true
    )
    @family.recurring_transactions.where.not(id: @series.id) # no-op, clarity
    accounts(:depository).entries.create!(
      date: Date.current.beginning_of_month + 8.days - 1.month, amount: 40,
      currency: "USD", name: "Gym", entryable: Transaction.new
    )
  end

  test "renders proposals as value-carrying checkboxes" do
    stub_provider(raw(amount: 45.0, frequency: "monthly", day_of_month: 9,
                      rationale: "Recent charges are 45"))

    get smart_configuration_bill_url(@series), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    # The checkbox IS the field: unchecked rows submit nothing.
    assert_select "input[type=checkbox][name=?][value=?]", "recurring_transaction[amount]", "45.0"
    assert_select "input[type=checkbox][name=?][value=?]", "recurring_transaction[frequency_preset]", "monthly"
    assert_select "form[action=?]", recurring_transaction_path(@series)
    assert_match "Recent charges are 45", response.body
  end

  test "an all-null suggestion means the bill is already right" do
    stub_provider(raw(confidence: 0.9))

    get smart_configuration_bill_url(@series), headers: { "Turbo-Frame" => "modal" }

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

  test "forbidden without an LLM provider" do
    Provider::Registry.stubs(:preferred_llm_provider).returns(nil)

    get smart_configuration_bill_url(@series)

    assert_response :forbidden
  end

  test "another family's bill is not found" do
    stub_provider(raw)
    other = families(:empty).recurring_transactions.create!(
      name: "Foreign", amount: 10, currency: "USD", expected_day_of_month: 1,
      last_occurrence_date: Date.current, next_expected_date: 1.month.from_now.to_date,
      status: "active"
    )

    get smart_configuration_bill_url(other)

    assert_response :not_found
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
