require "test_helper"

class PasskeyTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @passkey = passkeys(:bob_passkey)
  end

  test "belongs to user" do
    assert_equal @user, @passkey.user
  end

  test "validates presence of external_id" do
    passkey = Passkey.new(user: @user, public_key: "test")
    assert_not passkey.valid?
    assert_includes passkey.errors[:external_id], "can't be blank"
  end

  test "validates uniqueness of external_id" do
    passkey = Passkey.new(
      user: @user,
      external_id: @passkey.external_id,
      public_key: "test"
    )
    assert_not passkey.valid?
    assert_includes passkey.errors[:external_id], "has already been taken"
  end

  test "validates presence of public_key" do
    passkey = Passkey.new(user: @user, external_id: "unique-id")
    assert_not passkey.valid?
    assert_includes passkey.errors[:public_key], "can't be blank"
  end

  test "find_by_credential_id encodes credential id" do
    raw_credential_id = Base64.urlsafe_decode64(@passkey.external_id)
    found = Passkey.find_by_credential_id(raw_credential_id)
    assert_equal @passkey, found
  end

  test "find_by_credential_id returns nil for unknown credential" do
    assert_nil Passkey.find_by_credential_id("unknown-credential-id")
  end

  test "update_sign_count! updates sign_count and last_used_at" do
    freeze_time do
      @passkey.update_sign_count!(10)
      @passkey.reload

      assert_equal 10, @passkey.sign_count
      assert_equal Time.current, @passkey.last_used_at
    end
  end

  test "user can have multiple passkeys" do
    assert_equal 2, @user.passkeys.count
  end

  test "destroying user destroys passkeys" do
    passkey_ids = @user.passkeys.pluck(:id)
    assert passkey_ids.any?

    @user.destroy!

    passkey_ids.each do |id|
      assert_nil Passkey.find_by(id: id)
    end
  end
end
