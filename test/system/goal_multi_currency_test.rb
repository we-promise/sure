require "application_system_test_case"

class GoalMultiCurrencyTest < ApplicationSystemTestCase
  include BalanceTestHelper

  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @usd = @user.family.accounts.create!(name: "Dollar reserve", accountable: Depository.new, currency: "USD", balance: 500)
    @eur = @user.family.accounts.create!(name: "Euro reserve", accountable: Depository.new, currency: "EUR", balance: 1_000)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.current, rate: 1.2)
  end

  test "projection dates use the selected locale for ticks and tooltips" do
    @user.update!(locale: "ru")
    [ 70, 35, 0 ].each do |days_ago|
      create_balance(account: @usd, date: days_ago.days.ago.to_date, balance: 500)
    end
    goal = @user.family.goals.create!(name: "Travel", target_amount: 2_000, currency: "USD", target_date: 4.months.from_now.to_date) do |record|
      record.goal_accounts.build(account: @usd)
    end
    sign_in @user
    visit goal_path(goal)
    assert_selector "[data-controller='goal-projection-chart'] svg text"

    dates = page.evaluate_script(<<~JS)
      (() => {
        const chart = document.querySelector("[data-controller='goal-projection-chart']");
        const ticks = Array.from(chart.querySelectorAll("svg text")).filter((text) => text.__data__ instanceof Date);
        const overlay = chart.querySelector("svg rect[style*='cursor: crosshair']");
        const box = overlay.getBoundingClientRect();
        overlay.dispatchEvent(new PointerEvent("pointermove", { clientX: box.left + 1, clientY: box.top + 20, bubbles: true }));
        return {
          ticks: ticks.map((tick) => ({ label: tick.textContent, expected: new Intl.DateTimeFormat("ru", { month: "short", year: "numeric" }).format(tick.__data__) })),
          tooltip: chart.querySelector(".chart-tooltip").firstChild.textContent,
        };
      })()
    JS

    assert_not_empty dates["ticks"]
    dates["ticks"].each { |tick| assert_equal tick["expected"], tick["label"] }
    assert_match(/\A\d{1,2} [а-яё]+\.? \d{4} г\.\z/, dates["tooltip"])
  end

  test "create a goal backed by mixed currencies and show the converted total" do
    sign_in @user
    visit goals_path
    click_link I18n.t("goals.index.new_goal")

    within "turbo-frame#modal" do
      fill_in I18n.t("goals.form.fields.name"), with: "Travel reserve"
      fill_in I18n.t("goals.form.fields.target_amount"), with: "2000"
      check "goal_account_ids_#{@usd.id}"
      check "goal_account_ids_#{@eur.id}"
      earmark = I18n.t("goals.form.fields.earmark_for", account: @eur.name)
      fill_in earmark, with: "500"
      assert_text I18n.t("goals.form.earmark.converted").sub("{amount}", Money.new(600, "USD").format(precision: 0))
      # Past the €1,000 balance the goal counts its pro-rata share, not the typed amount.
      fill_in earmark, with: "2000"
      assert_text I18n.t("goals.form.earmark.converted").sub("{amount}", Money.new(1_200, "USD").format(precision: 0))
      fill_in earmark, with: ""
      click_button I18n.t("goals.form.create")
    end

    assert_text "Travel reserve"
    goal = @user.family.goals.find_by!(name: "Travel reserve")
    assert_current_path goal_path(goal)
    assert_equal "USD", goal.currency
    assert_equal 1_700, goal.current_balance
    assert_text Money.new(1_700, "USD").format(precision: 0)
    assert_text Money.new(1_000, "EUR").format(precision: 0)
    assert_text I18n.t("goals.show.funding_accounts.converted", amount: Money.new(1_200, "USD").format(precision: 0))
  end
end
