require "application_system_test_case"

class InstallmentPlanTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family = @user.family
    @card = @family.accounts.create!(
      name: "Plan Card",
      accountable: CreditCard.new,
      balance: 0,
      currency: "USD",
      owner: @user,
      status: "active"
    )
    @purchase = @card.entries.create!(
      date: Date.current,
      name: "Laptop Store",
      amount: 1200,
      currency: "USD",
      entryable: Transaction.new(kind: "standard", category: categories(:one))
    )
  end

  test "a manual card purchase becomes an installment plan" do
    visit transaction_path(@purchase)

    find("summary", text: /#{I18n.t("transactions.show.settings")}/i).click
    click_on I18n.t("transactions.show.installment_plan_action")

    within("dialog[open]") do
      assert_text "$100.00"
      fill_in I18n.t("installment_plans.new.interest_rate"), with: "12"
      fill_in I18n.t("installment_plans.new.term_months"), with: "12"
      assert_text "$106.62"
      click_on I18n.t("installment_plans.new.submit")
    end

    assert_text I18n.t("installment_plans.create.success")

    plan = @family.recurring_transactions.order(:created_at).last
    assert_equal "installment", plan.bill_type
    assert_equal 12, plan.end_after_count
    assert @purchase.reload.excluded?
  end
end
