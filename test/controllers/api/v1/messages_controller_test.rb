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

  test "should retry last assistant message" do
    skip "Retry functionality needs debugging"

    # Create an assistant message to retry
    assistant_message = @chat.messages.create!(
      type: "AssistantMessage",
      content: "Previous response",
      ai_model: "gpt-4"
    )

    assert_enqueued_with(job: AssistantResponseJob) do
      post "/api/v1/chats/#{@chat.id}/messages/retry",
        headers: bearer_auth_header(@write_token)
    end

    assert_response :accepted
    response_body = JSON.parse(response.body)
    assert response_body["message_id"].present?
  end

  test "should not retry if no assistant message exists" do
    # Remove all assistant messages
    @chat.messages.where(type: "AssistantMessage").destroy_all

    post "/api/v1/chats/#{@chat.id}/messages/retry.json",
      headers: bearer_auth_header(@write_token)

    assert_response :unprocessable_entity
    response_body = JSON.parse(response.body)
    assert_equal "No assistant message to retry", response_body["error"]
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

  test "omitted models use each authenticated user family configuration" do
    [ [ @user, "openai", "family-openai-model" ], [ users(:empty), "anthropic", "family-anthropic-model" ] ].each do |user, provider, model|
      user.family.create_ai_configuration!(provider: provider, model: model, api_key: "test-family-key")
      api_key = create_api_key(user)
      chat = user.chats.create!(title: "Family chat")
      post "/api/v1/chats/#{chat.id}/messages",
        params: { content: "Hello" },
        headers: api_headers(api_key)

      assert_response :created
      assert_equal model, chat.messages.find(JSON.parse(response.body)["id"]).ai_model
    end
  end

  test "explicit model overrides the family default" do
    @user.family.create_ai_configuration!(provider: "openai", model: "family-model", api_key: "test-family-key")
    api_key = create_api_key(@user)
    chat = @chat
    post "/api/v1/chats/#{chat.id}/messages",
        params: { content: "Hello", model: "requested-model" },
        headers: api_headers(api_key)

    assert_response :created
    assert_equal "requested-model", chat.messages.find(JSON.parse(response.body)["id"]).ai_model
  end

  test "omitted model preserves the installation default without a family configuration" do
    assert_nil @user.family.ai_configuration
    Setting.stubs(:llm_provider).returns("openai")
    Provider::Openai.stubs(:configured?).returns(true)
    Provider::Openai.stubs(:effective_model).returns("legacy-global-model")
    api_key = create_api_key(@user)
    chat = @chat
    post "/api/v1/chats/#{chat.id}/messages",
        params: { content: "Hello" },
        headers: api_headers(api_key)

    assert_response :created
    assert_equal "legacy-global-model", chat.messages.find(JSON.parse(response.body)["id"]).ai_model
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end

    def create_api_key(user)
      ApiKey.create!(user: user, name: "Family AI Test Key", scopes: [ "read_write" ], source: "web", display_key: ApiKey.generate_secure_key)
    end

    def bearer_auth_header(token)
      { "Authorization" => "Bearer #{token.token}" }
    end
end
