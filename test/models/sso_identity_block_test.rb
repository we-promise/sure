require "test_helper"

class SsoIdentityBlockTest < ActiveSupport::TestCase
  test "blocks an identity without storing its raw subject identifier" do
    identity = oidc_identities(:bob_google)

    SsoIdentityBlock.block_all!(OidcIdentity.where(id: identity.id), identity_label: identity.user.email)

    assert SsoIdentityBlock.blocked?(provider: identity.provider, uid: identity.uid)
    assert_not_equal identity.uid, SsoIdentityBlock.last.uid_digest
  end

  test "blocking the same identity is idempotent" do
    identity = oidc_identities(:bob_google)

    assert_difference -> { SsoIdentityBlock.count }, 1 do
      2.times { SsoIdentityBlock.block_all!(OidcIdentity.where(id: identity.id), identity_label: identity.user.email) }
    end
  end

  test "uses a keyed digest instead of a plain subject hash" do
    uid = "predictable-subject"

    assert_equal SsoIdentityBlock.digest(uid), SsoIdentityBlock.digest(uid)
    assert_not_equal Digest::SHA256.hexdigest(uid), SsoIdentityBlock.digest(uid)
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
end
