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
end
