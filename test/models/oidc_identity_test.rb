require "test_helper"

class OidcIdentityTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @oidc_identity = oidc_identities(:bob_google)
  end

  test "belongs to user" do
    assert_equal @user, @oidc_identity.user
  end

  test "validates presence of provider" do
    @oidc_identity.provider = nil
    assert_not @oidc_identity.valid?
    assert_includes @oidc_identity.errors[:provider], "can't be blank"
  end

  test "validates presence of uid" do
    @oidc_identity.uid = nil
    assert_not @oidc_identity.valid?
    assert_includes @oidc_identity.errors[:uid], "can't be blank"
  end

  test "validates presence of user_id" do
    @oidc_identity.user_id = nil
    assert_not @oidc_identity.valid?
    assert_includes @oidc_identity.errors[:user_id], "can't be blank"
  end

  test "validates uniqueness of uid scoped to provider" do
    duplicate = OidcIdentity.new(
      user: users(:family_member),
      provider: @oidc_identity.provider,
      uid: @oidc_identity.uid
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:uid], "has already been taken"
  end

  test "allows same uid for different providers" do
    different_provider = OidcIdentity.new(
      user: users(:family_member),
      provider: "different_provider",
      uid: @oidc_identity.uid
    )

    assert different_provider.valid?
  end

  test "records authentication timestamp" do
    old_timestamp = @oidc_identity.last_authenticated_at
    travel_to 1.hour.from_now do
      @oidc_identity.record_authentication!
      assert @oidc_identity.last_authenticated_at > old_timestamp
    end
  end

  test "creates from omniauth hash" do
    auth = OmniAuth::AuthHash.new({
      provider: "google_oauth2",
      uid: "google-123456",
      info: {
        email: "test@example.com",
        name: "Test User",
        first_name: "Test",
        last_name: "User"
      }
    })

    identity = OidcIdentity.create_from_omniauth(auth, @user)

    assert identity.persisted?
    assert_equal "google_oauth2", identity.provider
    assert_equal "google-123456", identity.uid
    assert_equal "test@example.com", identity.info["email"]
    assert_equal "Test User", identity.info["name"]
    assert_equal @user, identity.user
    assert_not_nil identity.last_authenticated_at
  end

  # ── sync_user_attributes! ────────────────────────────────────────────────────

  test "sync_user_attributes! updates name when user has not manually changed it" do
    # bob_google fixture: stored info has first_name "Bob", user.first_name is "Bob"
    # IdP now returns "Robert" → user hasn't changed from "Bob", so sync should apply
    auth = OmniAuth::AuthHash.new({
      provider: "openid_connect",
      uid: "google-uid-12345",
      info: { email: "bob@bobdylan.com", name: "Robert Dylan",
              first_name: "Robert", last_name: "Dylan" }
    })

    @oidc_identity.sync_user_attributes!(auth)

    assert_equal "Robert", @user.reload.first_name
    assert_equal "Dylan",  @user.reload.last_name
  end

  test "sync_user_attributes! does NOT overwrite name when user manually changed it" do
    # User changed their name from the IdP-stored "Bob" to "Bobby"
    @user.update!(first_name: "Bobby")

    auth = OmniAuth::AuthHash.new({
      provider: "openid_connect",
      uid: "google-uid-12345",
      info: { email: "bob@bobdylan.com", name: "Robert Dylan",
              first_name: "Robert", last_name: "Dylan" }
    })

    @oidc_identity.sync_user_attributes!(auth)

    # "Bobby" is a manual change — must be preserved
    assert_equal "Bobby", @user.reload.first_name
  end

  test "sync_user_attributes! preserves name when IdP provides no first_name" do
    @user.update!(first_name: "Bobby")

    auth = OmniAuth::AuthHash.new({
      provider: "openid_connect",
      uid: "google-uid-12345",
      info: { email: "bob@bobdylan.com" }
    })

    @oidc_identity.sync_user_attributes!(auth)

    assert_equal "Bobby", @user.reload.first_name
  end

  test "sync_user_attributes! stores latest IdP info regardless of name sync" do
    auth = OmniAuth::AuthHash.new({
      provider: "openid_connect",
      uid: "google-uid-12345",
      info: { email: "newemail@example.com", name: "Robert Dylan",
              first_name: "Robert", last_name: "Dylan" }
    })

    @oidc_identity.sync_user_attributes!(auth)

    assert_equal "newemail@example.com", @oidc_identity.reload.info["email"]
    assert_equal "Robert", @oidc_identity.reload.info["first_name"]
  end
end
