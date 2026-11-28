require "test_helper"

class Bills::ForecastReviewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    # ai_enabled? also depends on the install having credentials; the provider
    # stub below is what each test varies.
    User.any_instance.stubs(:ai_enabled?).returns(true)
  end

  test "seeds a chat with the forecast written into the prompt" do
    Provider::Registry.stubs(:preferred_llm_provider).returns(Object.new)
    row = SpendingForecast::Row.new(
      category: categories(:food_and_drink),
      typical: Money.new(200, @user.family.currency),
      spent: Money.new(50, @user.family.currency),
      remaining: Money.new(150, @user.family.currency)
    )
    SpendingForecast.any_instance.stubs(:rows).returns([ row ])
    SpendingForecast.any_instance.stubs(:history_months).returns(3)

    assert_difference "@user.chats.count", 1 do
      post forecast_review_bills_url
    end

    chat = @user.chats.order(created_at: :desc).first
    assert_redirected_to chat_path(chat, thinking: true)
    content = chat.messages.find_by!(type: "UserMessage").content
    assert_includes content, "last 3 full months"
    assert_includes content, "#{categories(:food_and_drink).name}: typically #{row.typical.format}"
    assert_includes content, "suggest where I could cut back"
  end

  test "forbidden without an LLM provider" do
    Provider::Registry.stubs(:preferred_llm_provider).returns(nil)

    post forecast_review_bills_url

    assert_response :forbidden
  end
end
