# frozen_string_literal: true

require "test_helper"

class Api::V1::ChatsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(ai_enabled: true)

    @oauth_app = Doorkeeper::Application.create!(
      name: "Test API App",
      redirect_uri: "https://example.com/callback",
      scopes: "read write read_write"
    )

    @read_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
    )

    @write_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )

    @chat = chats(:one)
  end

  test "should require authentication" do
    get "/api/v1/chats"
    assert_response :unauthorized
  end

  test "should require AI to be enabled" do
    @user.update!(ai_enabled: false)

    get "/api/v1/chats", headers: bearer_auth_header(@read_token)
    assert_response :forbidden

    response_body = JSON.parse(response.body)
    assert_equal "feature_disabled", response_body["error"]
  end

  test "should list chats with read scope" do
    get "/api/v1/chats", headers: bearer_auth_header(@read_token)
    assert_response :success

    response_body = JSON.parse(response.body)
    assert response_body["chats"].is_a?(Array)
    assert response_body["pagination"].present?
  end

  test "should show chat with messages" do
    get "/api/v1/chats/#{@chat.id}", headers: bearer_auth_header(@read_token)
    assert_response :success

    response_body = JSON.parse(response.body)
    assert_equal @chat.id, response_body["id"]
    assert response_body["messages"].is_a?(Array)
  end

  # Pagy v9 silently ignores the v6 `items:` key, which shipped a null `per_page`
  # and a 20-message page to clients. Assert the reported page size so the
  # regression cannot come back unnoticed.
  test "should report the configured page size in pagination" do
    get "/api/v1/chats", headers: bearer_auth_header(@read_token)
    assert_response :success
    assert_equal 20, JSON.parse(response.body).dig("pagination", "per_page")

    get "/api/v1/chats/#{@chat.id}", headers: bearer_auth_header(@read_token)
    assert_response :success
    assert_equal 50, JSON.parse(response.body).dig("pagination", "per_page")
  end

  test "should return the newest messages on the first page, ordered chronologically" do
    5.times do |i|
      UserMessage.create!(
        chat: @chat,
        content: "msg #{i}",
        ai_model: "test",
        created_at: Time.current + i.minutes
      )
    end

    get "/api/v1/chats/#{@chat.id}?per_page=2", headers: bearer_auth_header(@read_token)
    assert_response :success

    response_body = JSON.parse(response.body)
    assert_equal [ "msg 3", "msg 4" ], response_body["messages"].map { |m| m["content"] }
    assert_equal 2, response_body.dig("pagination", "per_page")
  end

  test "should create chat with write scope" do
    assert_difference "Chat.count" do
      post "/api/v1/chats",
        params: { title: "New chat", message: "Hello AI" },
        headers: bearer_auth_header(@write_token)
    end

    assert_response :created
    response_body = JSON.parse(response.body)
    assert_equal "New chat", response_body["title"]
  end

  test "should not create chat with read scope" do
    post "/api/v1/chats",
      params: { title: "New chat" },
      headers: bearer_auth_header(@read_token)

    assert_response :forbidden
  end

  test "should update chat" do
    patch "/api/v1/chats/#{@chat.id}",
      params: { title: "Updated title" },
      headers: bearer_auth_header(@write_token)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal "Updated title", response_body["title"]
  end

  test "should delete chat" do
    assert_difference "Chat.count", -1 do
      delete "/api/v1/chats/#{@chat.id}", headers: bearer_auth_header(@write_token)
    end

    assert_response :no_content
  end

  test "should not access other user's chat" do
    other_user = users(:family_member)
    other_user.update!(family: families(:empty))
    other_chat = chats(:two)
    other_chat.update!(user: other_user)

    get "/api/v1/chats/#{other_chat.id}", headers: bearer_auth_header(@read_token)
    assert_response :not_found
  end

  test "should support API key authentication" do
    # Remove any existing API keys for this user
    @user.api_keys.destroy_all

    plain_key = ApiKey.generate_secure_key
    api_key = @user.api_keys.build(
      name: "Test API Key",
      scopes: [ "read_write" ]
    )
    api_key.key = plain_key
    api_key.save!

    get "/api/v1/chats", headers: { "X-Api-Key" => plain_key }
    assert_response :success
  end

  test "API key authentication should not inherit web session impersonation" do
    support_user = users(:sure_support_staff)
    support_user.update!(ai_enabled: true)
    support_user.api_keys.active.destroy_all
    support_chat = support_user.chats.create!(title: "Support Chat")

    token_value = ApiKey.generate_secure_key
    credential = support_user.api_keys.build(
      name: "Impersonation Guard Credential",
      scopes: [ "read" ]
    )
    credential.key = token_value
    credential.save!

    impersonation_session = impersonation_sessions(:in_progress)
    impersonated_chat = impersonation_session.impersonated.chats.create!(title: "Impersonated Chat")
    support_user.sessions.destroy_all
    support_user.sessions.create!(
      user_agent: "Browser session",
      ip_address: "127.0.0.1",
      active_impersonator_session: impersonation_session
    )

    get "/api/v1/chats", headers: { "X-Api-Key" => token_value }

    assert_response :success
    response_body = JSON.parse(response.body)
    chat_ids = response_body["chats"].pluck("id")

    assert_includes chat_ids, support_chat.id
    assert_not_includes chat_ids, impersonated_chat.id
  end

  test "OAuth authentication should not inherit web session impersonation" do
    support_user = users(:sure_support_staff)
    support_user.update!(ai_enabled: true)
    support_chat = support_user.chats.create!(title: "Support Chat")
    support_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: support_user.id,
      scopes: "read"
    )

    impersonation_session = impersonation_sessions(:in_progress)
    impersonated_chat = impersonation_session.impersonated.chats.create!(title: "Impersonated Chat")
    support_user.sessions.destroy_all
    support_user.sessions.create!(
      user_agent: "Browser session",
      ip_address: "127.0.0.1",
      active_impersonator_session: impersonation_session
    )

    get "/api/v1/chats", headers: bearer_auth_header(support_token)

    assert_response :success
    response_body = JSON.parse(response.body)
    chat_ids = response_body["chats"].pluck("id")

    assert_includes chat_ids, support_chat.id
    assert_not_includes chat_ids, impersonated_chat.id
  end

  private

    def bearer_auth_header(token)
      { "Authorization" => "Bearer #{token.token}" }
    end
end
