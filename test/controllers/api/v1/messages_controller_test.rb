# frozen_string_literal: true

require "test_helper"

class Api::V1::MessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(ai_enabled: true)

    @oauth_app = Doorkeeper::Application.create!(
      name: "Test API App",
      redirect_uri: "https://example.com/callback",
      scopes: "read write read_write"
    )

    @write_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )

    @chat = chats(:one)
  end

  test "should require authentication" do
    post "/api/v1/chats/#{@chat.id}/messages"
    assert_response :unauthorized
  end

  test "should require AI to be enabled" do
    @user.update!(ai_enabled: false)

    post "/api/v1/chats/#{@chat.id}/messages",
      params: { content: "Hello" },
      headers: bearer_auth_header(@write_token)
    assert_response :forbidden
  end

  test "should create message with write scope" do
    assert_difference "UserMessage.count" do
      post "/api/v1/chats/#{@chat.id}/messages",
        params: { content: "Test message", model: "gpt-4" },
        headers: bearer_auth_header(@write_token)
    end

    assert_response :created
    response_body = JSON.parse(response.body)
    assert_equal "Test message", response_body["content"]
    assert_equal "user_message", response_body["type"]
    assert_equal "pending", response_body["ai_response_status"]
  end

  test "should enqueue assistant response job" do
    assert_enqueued_with(job: AssistantResponseJob) do
      post "/api/v1/chats/#{@chat.id}/messages",
        params: { content: "Test message" },
        headers: bearer_auth_header(@write_token)
    end
  end

  test "retries a failed reply and keeps the tool calls it ran" do
    failed = @chat.messages.create!(type: "AssistantMessage", content: "", ai_model: "gpt-4.1", status: :failed)
    tool_call = ToolCall::Function.create!(message: failed, provider_id: "fc_1", provider_call_id: "call_1", function_name: "create_tag",
                                           function_arguments: { name: "Groceries" }, function_result: { success: true })

    assert_enqueued_with(job: AssistantResponseJob) do
      post "/api/v1/chats/#{@chat.id}/messages/retry", headers: bearer_auth_header(@write_token)
    end

    assert_response :accepted
    reply = AssistantMessage.find(JSON.parse(response.body)["message_id"])
    assert reply.pending?
    assert_equal [ tool_call.id ], failed.tool_calls.pluck(:id)
  end

  test "retries when the last reply never arrived" do
    @chat.messages.where(type: "AssistantMessage").destroy_all

    assert_enqueued_with(job: AssistantResponseJob) do
      post "/api/v1/chats/#{@chat.id}/messages/retry", headers: bearer_auth_header(@write_token)
    end

    assert_response :accepted
  end

  test "does not retry a reply that finished" do
    assert_no_enqueued_jobs(only: AssistantResponseJob) do
      post "/api/v1/chats/#{@chat.id}/messages/retry.json", headers: bearer_auth_header(@write_token)
    end

    assert_response :unprocessable_entity
    assert_equal "No assistant message to retry", JSON.parse(response.body)["error"]
  end

  test "should not access messages in other user's chat" do
    other_user = users(:family_member)
    other_user.update!(family: families(:empty))
    other_chat = chats(:two)
    other_chat.update!(user: other_user)

    post "/api/v1/chats/#{other_chat.id}/messages",
      params: { content: "Test" },
      headers: bearer_auth_header(@write_token)

    assert_response :not_found
  end

  private

    def bearer_auth_header(token)
      { "Authorization" => "Bearer #{token.token}" }
    end
end
