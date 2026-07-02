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
      display_key: "listed_key_123",
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
      display_key: "existing_key_123",
      scopes: [ "read" ]
    )

    get new_settings_api_key_path
    assert_response :success
  end

  test "create makes a new key without revoking existing keys" do
    existing = ApiKey.create!(
      user: @user,
      name: "Existing API Key",
      display_key: "existing_key_123",
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
    assert_redirected_to settings_api_key_path(new_key, newly_created: true)

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
      display_key: "dup_key_123",
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

  test "show renders a key" do
    created_key = ApiKey.create!(
      user: @user,
      name: "Test API Key",
      display_key: "test_key_123",
      scopes: [ "read" ]
    )

    get settings_api_key_path(created_key)
    assert_response :success
    assert_includes response.body, "Test API Key"
  end

  test "show renders the newly created confirmation" do
    created_key = ApiKey.create!(
      user: @user,
      name: "Fresh Key",
      display_key: "fresh_key_123",
      scopes: [ "read" ]
    )

    get settings_api_key_path(created_key, newly_created: true)
    assert_response :success
    assert_includes response.body, created_key.plain_key
    assert_select "h3", text: I18n.t("settings.api_keys.show.newly_created.heading")
  end

  test "show 404s on another user's key" do
    other_user = users(:family_member)
    other_user.api_keys.destroy_all
    other_key = ApiKey.create!(
      user: other_user,
      name: "Other User Key",
      display_key: "other_user_key_123",
      scopes: [ "read" ]
    )

    get settings_api_key_path(other_key)
    assert_response :not_found
  end

  test "destroy revokes the targeted key only" do
    key1 = ApiKey.create!(
      user: @user,
      name: "Key One",
      display_key: "key_one_123",
      scopes: [ "read" ]
    )
    key2 = ApiKey.create!(
      user: @user,
      name: "Key Two",
      display_key: "key_two_123",
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
      display_key: ApiKey::DEMO_MONITORING_KEY,
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
    assert_redirected_to settings_api_key_path(created_key, newly_created: true)
    assert_includes created_key.scopes, "read"
    assert_equal 64, created_key.plain_key.length
  end

  # API keys are user-scoped self-management: a member manages their own keys
  # (a key carries only the owning user's permissions, and members reach this
  # page via the Reports CSV/export flow). Do NOT add an admin gate here.
  test "non-admin member can view API key settings" do
    sign_in users(:family_member)
    get settings_api_key_path
    assert_response :success
  end

  test "non-admin member can create their own API key" do
    sign_in users(:family_member)
    assert_difference "ApiKey.count", 1 do
      post settings_api_key_path, params: {
        api_key: { name: "Member Key", scopes: "read" }
      }
    end
    assert_redirected_to settings_api_key_path
  end
end
