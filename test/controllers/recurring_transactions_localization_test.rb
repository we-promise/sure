require "test_helper"

class RecurringTransactionsLocalizationTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @recurring_transaction = recurring_transactions(:netflix_subscription)
    ensure_tailwind_build
  end

  test "German edit form renders localized recurrence rule errors" do
    patch recurring_transaction_url(@recurring_transaction, locale: :de),
          params: { recurring_transaction: { frequency_preset: "weekly" } },
          headers: { "Turbo-Frame" => "modal" }

    assert_response :unprocessable_entity
    assert_includes response.body, "Wochentag muss für eine wöchentliche Regel angegeben werden"
    assert_no_match(/Recurrence rules/, response.body)
    assert_no_match(/Weekday is required for a weekly rule/, response.body)
  end
end
