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
end
