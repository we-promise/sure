require "test_helper"

class BudgetRolloverLocalizationTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in @user = users(:family_admin)
    @budget = budgets(:one)
    @category = @budget.family.categories.create!(name: "Synthetic rollover category", color: "#4da568")
    @budget_category = @budget.budget_categories.create!(
      category: @category, budgeted_spending: 100, currency: "USD", rollover_enabled: true
    )
  end

  test "German rollover translations exist without fallback and preserve the amount" do
    I18n.with_locale(:de) do
      {
        "budget_category.rolled_over" => "+25,00 € übertragen",
        "budget_category_form.rollover_label" => "Übertrag",
        "budget_category_form.rollover_title" => "Nicht ausgegebenes Geld dieser Kategorie in den nächsten Monat übertragen",
        "show.rolled_over" => "Übertragen"
      }.each do |key, expected|
        full_key = "budget_categories.#{key}"
        assert I18n.exists?(full_key, :de, fallback: false)
        assert_equal expected, I18n.t(full_key, amount: "25,00 €")
      end
    end
  end

  test "German category form renders the rollover label and tooltip" do
    @user.update!(locale: "de")
    get budget_budget_categories_path(@budget)

    assert_response :success
    assert_select "label", text: "Übertrag"
    assert_select "div[title=?]", "Nicht ausgegebenes Geld dieser Kategorie in den nächsten Monat übertragen"
  end

  test "German category detail renders the carried amount label" do
    @user.update!(locale: "de")
    previous = @budget.family.budgets.create!(
      start_date: 1.month.ago.beginning_of_month.to_date,
      end_date: 1.month.ago.end_of_month.to_date,
      budgeted_spending: 25, expected_income: 100, currency: "USD"
    )
    previous.budget_categories.create!(
      category: @category, budgeted_spending: 25, currency: "USD", rollover_enabled: true
    )
    get budget_budget_category_path(@budget, @budget_category)

    assert_response :success
    assert_select "dt", text: "Übertragen"

    get budget_url(Budget.date_to_param(Date.current))

    assert_response :success
    assert_select "a[href=?]", budget_budget_category_path(@budget, @budget_category), text: /\+.*25.*übertragen/
  end

  test "English category form preserves rollover copy" do
    @user.update!(locale: "en")
    get budget_budget_categories_path(@budget)

    assert_response :success
    assert_select "label", text: "Rollover"
    assert_select "div[title=?]", "Keep this category's unspent money from one month to the next"
  end
end
