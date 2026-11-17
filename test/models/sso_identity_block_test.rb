require "test_helper"

class SsoIdentityBlockTest < ActiveSupport::TestCase
  include SecretKeyBaseRotationHelper

  test "blocks an identity with its subject identifier encrypted" do
    identity = oidc_identities(:bob_google)

    SsoIdentityBlock.block_all!(OidcIdentity.where(id: identity.id), identity_label: identity.user.email)

    block = SsoIdentityBlock.last
    assert SsoIdentityBlock.blocked?(provider: identity.provider, uid: identity.uid)
    assert_equal identity.uid, block.uid
    assert_nil block.uid_digest
    assert_not_includes block.read_attribute_before_type_cast(:uid).to_s, identity.uid
  end

  test "blocking the same identity is idempotent" do
    identity = oidc_identities(:bob_google)

    assert_difference -> { SsoIdentityBlock.count }, 1 do
      2.times { SsoIdentityBlock.block_all!(OidcIdentity.where(id: identity.id), identity_label: identity.user.email) }
    end
  end

  test "a block survives a SECRET_KEY_BASE change" do
    identity = oidc_identities(:bob_google)
    SsoIdentityBlock.block_all!(OidcIdentity.where(id: identity.id), identity_label: identity.user.email)

    with_rotated_secret_key_base do
      assert SsoIdentityBlock.blocked?(provider: identity.provider, uid: identity.uid)
    end
  end

  test "a legacy digest block with its stored key survives a SECRET_KEY_BASE change" do
    key = Rails.application.key_generator.generate_key(SsoIdentityBlock::LEGACY_DIGEST_SALT, 32)
    SsoIdentityBlock.create!(
      provider: "openid_connect",
      uid_digest: SsoIdentityBlock.digest("legacy-subject", key: key),
      legacy_digest_key: Base64.strict_encode64(key),
      identity_label: "removed-user@example.com"
    )

    with_rotated_secret_key_base do
      assert SsoIdentityBlock.blocked?(provider: "openid_connect", uid: "legacy-subject")
      assert_not SsoIdentityBlock.blocked?(provider: "openid_connect", uid: "other-subject")
      assert_not SsoIdentityBlock.blocked?(provider: "google_oauth2", uid: "legacy-subject")
    end
  end

  test "a legacy digest block without a stored key matches with the current key" do
    SsoIdentityBlock.create!(
      provider: "openid_connect",
      uid_digest: SsoIdentityBlock.digest("legacy-subject"),
      identity_label: "removed-user@example.com"
    )

    assert SsoIdentityBlock.blocked?(provider: "openid_connect", uid: "legacy-subject")
    assert_not SsoIdentityBlock.blocked?(provider: "openid_connect", uid: "other-subject")
  end

  test "blocking an identity that a legacy digest already blocks adds no second block" do
    identity = oidc_identities(:bob_google)
    SsoIdentityBlock.create!(
      provider: identity.provider,
      uid_digest: SsoIdentityBlock.digest(identity.uid),
      identity_label: identity.user.email
    )

    assert_no_difference -> { SsoIdentityBlock.count } do
      SsoIdentityBlock.block_all!(OidcIdentity.where(id: identity.id), identity_label: identity.user.email)
    end
  end

  test "an unreadable stored key does not hide readable legacy keys and fails closed" do
    key = Rails.application.key_generator.generate_key(SsoIdentityBlock::LEGACY_DIGEST_SALT, 32)
    SsoIdentityBlock.create!(
      provider: "openid_connect",
      uid_digest: SsoIdentityBlock.digest("corrupt-subject", key: key),
      legacy_digest_key: "not base64 !",
      identity_label: "removed-user@example.com"
    )
    SsoIdentityBlock.create!(
      provider: "openid_connect",
      uid_digest: SsoIdentityBlock.digest("legacy-subject", key: key),
      legacy_digest_key: Base64.strict_encode64(key),
      identity_label: "removed-user@example.com"
    )
    SsoIdentityBlock.create!(provider: "openid_connect", uid: "new-subject", identity_label: "removed-user@example.com")

    with_rotated_secret_key_base do
      assert SsoIdentityBlock.blocked?(provider: "openid_connect", uid: "legacy-subject")
      assert SsoIdentityBlock.blocked?(provider: "openid_connect", uid: "new-subject")
      assert SsoIdentityBlock.blocked?(provider: "openid_connect", uid: "someone-else"),
        "an identity the unreadable rows might cover must not pass"
      assert_nil SsoIdentityBlock.find_block(provider: "openid_connect", uid: "someone-else")
      assert_not SsoIdentityBlock.blocked?(provider: "google_oauth2", uid: "someone-else")
    end
  end

  test "uses a keyed digest instead of a plain subject hash" do
    uid = "predictable-subject"

    assert_equal SsoIdentityBlock.digest(uid), SsoIdentityBlock.digest(uid)
    assert_not_equal Digest::SHA256.hexdigest(uid), SsoIdentityBlock.digest(uid)
  end

  test "requires a subject identifier or a digest" do
    block = SsoIdentityBlock.new(provider: "openid_connect", identity_label: "removed-user@example.com")

    assert_not block.valid?
    assert block.errors.added?(:uid, :blank)
  end

  test "does not store the identity label in plaintext without encryption" do
    SsoIdentityBlock.stubs(:encryption_ready?).returns(false)
    raw_label = "removed-user@example.com"

    block = SsoIdentityBlock.create!(
      provider: "openid_connect",
      uid_digest: SsoIdentityBlock.digest("removed-subject"),
      identity_label: raw_label
    )

    assert_not_equal raw_label, block.identity_label
    assert_match(/Removed identity/, block.identity_label)
  end

  test "stores a digest instead of the subject identifier without encryption" do
    SsoIdentityBlock.stubs(:encryption_ready?).returns(false)
    identity = oidc_identities(:bob_google)

    SsoIdentityBlock.block_all!(OidcIdentity.where(id: identity.id), identity_label: identity.user.email)

    block = SsoIdentityBlock.last
    assert_nil block.read_attribute_before_type_cast(:uid)
    assert_equal SsoIdentityBlock.digest(identity.uid), block.uid_digest
    assert SsoIdentityBlock.blocked?(provider: identity.provider, uid: identity.uid)
  end
end
