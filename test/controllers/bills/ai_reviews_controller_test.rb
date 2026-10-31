require "test_helper"

class Bills::AiReviewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
  end

  test "seeds a chat with the server-owned review prompt" do
    stub_provider

    assert_difference "@user.chats.count", 1 do
      post ai_review_bills_url
    end

    chat = @user.chats.order(created_at: :desc).first
    assert_redirected_to chat_path(chat, thinking: true)
    content = chat.messages.find_by!(type: "UserMessage").content
    assert_includes content, "Review my bills and subscriptions"
    assert_includes content, "ask me before changing anything"
    # The prompt appears in the chat as the user's own words, so it must not
    # leak internal tool names; the tool descriptions route the model.
    assert_no_match(/get_bill/, content)
    assert_equal chat, @user.reload.last_viewed_chat
  end

  test "forbidden when AI is disabled" do
    stub_provider
    @user.update!(ai_enabled: false)

    post ai_review_bills_url

    assert_response :forbidden
  end

  test "forbidden without an LLM provider" do
    Provider::Registry.stubs(:preferred_llm_provider).returns(nil)

    post ai_review_bills_url

    assert_response :forbidden
  end

  test "redirects when the family has recurring transactions off" do
    stub_provider
    @user.family.update!(recurring_transactions_disabled: true)

    post ai_review_bills_url

    assert_redirected_to root_path
  end

  test "refuses GET" do
    route = Rails.application.routes.recognize_path("/bills/ai_review", method: :get)
    assert_equal "show", route[:action], "GET must never reach the review action"
  end

  private

    def stub_provider
      Provider::Registry.stubs(:preferred_llm_provider).returns(Object.new)
    end
end
