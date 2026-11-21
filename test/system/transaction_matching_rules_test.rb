require "application_system_test_case"

class TransactionMatchingRulesTest < ApplicationSystemTestCase
  include ActionView::RecordIdentifier

  setup do
    sign_in @user = users(:family_admin)
    @entry = entries(:transaction)
    @user.family.rules.destroy_all
    rule = @user.family.rules.build(name: "Coffee shops", resource_type: "transaction", active: true)
    rule.conditions.build(condition_type: "transaction_name", operator: "like", value: "starbucks")
    rule.actions.build(action_type: "set_transaction_category", value: categories(:income).id)
    rule.save!
  end

  test "the drawer checks the rules only when asked" do
    visit transactions_url
    page.execute_script <<~JS
      document.querySelector("turbo-frame#drawer").src = "#{transaction_url(@entry)}"
    JS

    within "turbo-frame#drawer dialog[open]" do
      frame = "turbo-frame##{dom_id(@entry, :matching_rules)}"
      assert_no_selector "#{frame}[complete]", visible: :all

      find("summary", text: "Which rules match?").click

      within frame do
        assert_selector "[data-testid='matching-rule']", text: "Coffee shops"
        assert_text "Income"
      end
    end
  end
end
