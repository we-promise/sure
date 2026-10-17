require "test_helper"

class Settings::ApiKeysControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.api_keys.destroy_all # Ensure clean state
    sign_in @user
  end

  test "index shows api keys list" do
    ApiKey.create!(
      user: @user,
      name: "Listed Key",
      key: "listed_key_123",
      scopes: [ "read" ]
    )

    get settings_api_keys_path
    assert_response :success
    assert_includes response.body, "Listed Key"
  end

  test "new always renders form (no redirect when key exists)" do
    ApiKey.create!(
      user: @user,
      name: "Existing API Key",
      key: "existing_key_123",
      scopes: [ "read" ]
    )

    get new_settings_api_key_path
    assert_response :success
  end

  test "new shows the name hint under the field and points the input at it" do
    get new_settings_api_key_path
    assert_response :success

    assert_select "p#api_key_name_help_text", text: "Choose a descriptive name to help you identify this key later."
    assert_select "input[name='api_key[name]'][aria-describedby=?]", "api_key_name_help_text"
    assert_select "input[help_text]", count: 0
  end

  test "create makes a new key without revoking existing keys" do
    existing = ApiKey.create!(
      user: @user,
      name: "Existing API Key",
      key: "existing_key_123",
      scopes: [ "read" ]
    )

    assert_difference "ApiKey.count", 1 do
      post settings_api_keys_path, params: {
        api_key: {
          name: "Brand New Key",
          scopes: "read_write"
        }
      }
    end

    new_key = @user.api_keys.active.visible.find_by(name: "Brand New Key")
    assert new_key.present?
    assert_redirected_to settings_api_key_path(new_key)

    existing.reload
    refute existing.revoked?
    assert_includes new_key.scopes, "read_write"
  end

  test "create rejects blank name" do
    assert_no_difference "ApiKey.count" do
      post settings_api_keys_path, params: {
        api_key: {
          name: "",
          scopes: "read"
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "create rejects blank scopes" do
    assert_no_difference "ApiKey.count" do
      post settings_api_keys_path, params: {
        api_key: {
          name: "No Scopes Key",
          scopes: []
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "create rejects duplicate active name" do
    ApiKey.create!(
      user: @user,
      name: "Dup",
      key: "dup_key_123",
      scopes: [ "read" ]
    )

    assert_no_difference "ApiKey.count" do
      post settings_api_keys_path, params: {
        api_key: {
          name: "Dup",
          scopes: "read_write"
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "show renders a key without revealing its secret" do
    created_key = ApiKey.create!(
      user: @user,
      name: "Test API Key",
      key: "test_key_123",
      scopes: [ "read" ]
    )

    get settings_api_key_path(created_key)
    assert_response :success
    assert_includes response.body, "Test API Key"
    assert_not_includes response.body, "test_key_123"
    assert_includes response.body, "Starts with test_key"
    assert_includes response.body, "YOUR_API_KEY"
  end

  test "the full key is shown once after creation and never again" do
    post settings_api_keys_path, params: { api_key: { name: "Fresh Key", scopes: "read" } }

    created_key = @user.api_keys.active.visible.find_by!(name: "Fresh Key")
    follow_redirect!
    assert_response :success

    plain_key = revealed_key
    assert_equal 64, plain_key.length
    assert_equal ApiKey.digest(plain_key), created_key.key_digest
    assert_select "h3", text: I18n.t("settings.api_keys.show.newly_created.heading")
    assert_select "div#newly_created_api_key_reveal[data-turbo-permanent]"

    # Reloading the same URL (or visiting it later) must not reveal the key.
    get settings_api_key_path(created_key)
    assert_response :success
    assert_not_includes response.body, plain_key
    assert_includes response.body, "Starts with #{plain_key.first(ApiKey::KEY_PREFIX_LENGTH)}"
    assert_select "h3", text: I18n.t("settings.api_keys.show.newly_created.heading"), count: 0
  end

  test "a newly created key authenticates API requests" do
    post settings_api_keys_path, params: { api_key: { name: "Usable Key", scopes: "read" } }
    follow_redirect!

    plain_key = revealed_key
    assert_equal @user.api_keys.find_by!(name: "Usable Key"), ApiKey.find_by_value(plain_key)
  end

  test "show 404s on another user's key" do
    other_user = users(:family_member)
    other_user.api_keys.destroy_all
    other_key = ApiKey.create!(
      user: other_user,
      name: "Other User Key",
      key: "other_user_key_123",
      scopes: [ "read" ]
    )

    get settings_api_key_path(other_key)
    assert_response :not_found
  end

  test "destroy revokes the targeted key only" do
    key1 = ApiKey.create!(
      user: @user,
      name: "Key One",
      key: "key_one_123",
      scopes: [ "read" ]
    )
    key2 = ApiKey.create!(
      user: @user,
      name: "Key Two",
      key: "key_two_123",
      scopes: [ "read_write" ]
    )

    delete settings_api_key_path(key1)
    assert_redirected_to settings_api_keys_path

    key1.reload
    key2.reload
    assert key1.revoked?
    refute key2.revoked?
  end

  test "destroy cannot revoke demo monitoring key" do
    # set_api_key scopes to .visible which EXCLUDES the demo key, so the
    # demo key id is not found by the controller and the request 404s
    # before reaching the cannot_revoke branch.
    demo_key = ApiKey.create!(
      user: @user,
      name: "Demo Monitoring Key",
      key: ApiKey::DEMO_MONITORING_KEY,
      scopes: [ "read" ]
    )

    delete settings_api_key_path(demo_key)
    assert_response :not_found

    demo_key.reload
    refute demo_key.revoked?
  end

  test "create generates a secure random API key" do
    post settings_api_keys_path, params: {
      api_key: {
        name: "Random Key Test",
        scopes: "read"
      }
    }

    created_key = @user.api_keys.active.visible.find_by(name: "Random Key Test")
    assert created_key.present?
    assert_redirected_to settings_api_key_path(created_key)
    assert_includes created_key.scopes, "read"
    assert_equal ApiKey::KEY_PREFIX_LENGTH, created_key.key_prefix.length
    assert_nil created_key.display_key
  end

  # API keys are user-scoped self-management: a member manages their own keys
  # (a key carries only the owning user's permissions, and members reach this
  # page via the Reports CSV/export flow). Do NOT add an admin gate here.
  test "non-admin member can view API keys list" do
    sign_in users(:family_member)
    get settings_api_keys_path
    assert_response :success
  end

  test "non-admin member can create their own API key" do
    member = users(:family_member)
    member.api_keys.destroy_all
    sign_in member

    assert_difference "ApiKey.count", 1 do
      post settings_api_keys_path, params: {
        api_key: { name: "Member Key", scopes: "read" }
      }
    end

    new_key = member.api_keys.active.visible.find_by(name: "Member Key")
    assert new_key.present?
    assert_redirected_to settings_api_key_path(new_key)
  end

  test "visiting another key does not leak or consume pending secret for created key" do
    other_key = ApiKey.create!(
      user: @user,
      name: "Other Key",
      key: "other_key_secret_123",
      scopes: [ "read" ]
    )

    post settings_api_keys_path, params: { api_key: { name: "New Secret Key", scopes: "read" } }
    created_key = @user.api_keys.active.visible.find_by!(name: "New Secret Key")

    # Visiting another key must not display the newly created secret or consume it
    get settings_api_key_path(other_key)
    assert_response :success
    assert_not_includes response.body, "other_key_secret_123"
    assert_select "code[data-clipboard-target='source']", count: 0

    # Visiting the actual created key still reveals its secret
    get settings_api_key_path(created_key)
    assert_response :success
    plain_key = revealed_key
    assert_equal 64, plain_key.length
    assert_equal ApiKey.digest(plain_key), created_key.key_digest
  end

  test "newly created key view specifies turbo-cache-control no-cache" do
    post settings_api_keys_path, params: { api_key: { name: "Cache Control Key", scopes: "read" } }
    created_key = @user.api_keys.active.visible.find_by!(name: "Cache Control Key")

    follow_redirect!
    assert_response :success
    assert_select "meta[name='turbo-cache-control'][content='no-cache']"

    # Subsequent visit without the secret does not set turbo-cache-control no-cache
    get settings_api_key_path(created_key)
    assert_response :success
    assert_select "meta[name='turbo-cache-control'][content='no-cache']", count: 0
  end

  private

    # The key shown on the "created" page, read from the clipboard source element.
    def revealed_key
      css_select("code[data-clipboard-target='source']").first&.text.to_s.strip
    end
end
