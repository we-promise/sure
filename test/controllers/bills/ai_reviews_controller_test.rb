require "test_helper"

class Bills::AiReviewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "seeds a chat with the server-owned review prompt" do
    assert_difference "@user.chats.count", 1 do
      post ai_review_bills_url
    end

    chat = @user.chats.order(created_at: :desc).first
    assert_redirected_to chat_path(chat, thinking: true)
    assert_includes chat.messages.find_by!(type: "UserMessage").content, "get_bill_audit"
    assert_equal chat, @user.reload.last_viewed_chat
  end

  test "forbidden when AI is disabled" do
    @user.update!(ai_enabled: false)

    post ai_review_bills_url

    assert_response :forbidden
  end

  test "redirects when the family has recurring transactions off" do
    @user.family.update!(recurring_transactions_disabled: true)

    post ai_review_bills_url

    assert_redirected_to root_path
  end

  test "refuses GET" do
    route = Rails.application.routes.recognize_path("/bills/ai_review", method: :get)
    assert_equal "show", route[:action], "GET must never reach the review action"
  end
end
