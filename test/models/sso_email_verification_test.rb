require "test_helper"

class SsoEmailVerificationTest < ActiveSupport::TestCase
  setup do
    Rails.configuration.x.auth.stubs(:sso_providers).returns([
      { name: "openid_connect", strategy: "openid_connect" },
      { name: "google_oauth2", strategy: "google_oauth2" },
      { name: "github", strategy: "github" },
      { name: "corp_saml", strategy: "saml" },
      { name: "corp_oidc", strategy: "openid_connect", settings: { "treat_email_as_verified" => "1" } },
      { name: "off_oidc", strategy: "openid_connect", settings: { "treat_email_as_verified" => "0" } }
    ])
  end

  def auth(provider:, email: "user@example.com", info: {}, extra: {})
    OmniAuth::AuthHash.new(provider: provider, uid: "uid-1", info: { email: email }.merge(info), extra: extra)
  end

  test "accepts the email_verified claim as a boolean or the string true" do
    assert SsoEmailVerification.verified?(auth(provider: "openid_connect", info: { email_verified: true }))
    assert SsoEmailVerification.verified?(auth(provider: "openid_connect", extra: { raw_info: { "email_verified" => "true" } }))
    assert SsoEmailVerification.verified?(auth(provider: "google_oauth2", info: { email_verified: true }))
  end

  test "rejects a false or missing email_verified claim" do
    assert_not SsoEmailVerification.verified?(auth(provider: "openid_connect", info: { email_verified: false }))
    assert_not SsoEmailVerification.verified?(auth(provider: "openid_connect", extra: { raw_info: { "email_verified" => "false" } }))
    assert_not SsoEmailVerification.verified?(auth(provider: "openid_connect"))
  end

  test "rejects an auth without an email" do
    assert_not SsoEmailVerification.verified?(auth(provider: "openid_connect", email: nil, info: { email_verified: true }))
  end

  test "uses github's verified flag for the returned email" do
    verified = [ { "email" => "user@example.com", "primary" => true, "verified" => true } ]
    unverified = [ { "email" => "user@example.com", "primary" => true, "verified" => false } ]

    assert SsoEmailVerification.verified?(auth(provider: "github", extra: { all_emails: verified }))
    assert_not SsoEmailVerification.verified?(auth(provider: "github", extra: { all_emails: unverified }))
    assert_not SsoEmailVerification.verified?(auth(provider: "github"))
  end

  test "accepts Entra ID's xms_edov claim when email_verified is missing" do
    assert SsoEmailVerification.verified?(auth(provider: "openid_connect", extra: { raw_info: { "xms_edov" => true } }))
    assert SsoEmailVerification.verified?(auth(provider: "openid_connect", extra: { raw_info: { "xms_edov" => "true" } }))
    assert_not SsoEmailVerification.verified?(auth(provider: "openid_connect", extra: { raw_info: { "xms_edov" => false } }))
  end

  test "does not let xms_edov override an explicit false email_verified" do
    assert_not SsoEmailVerification.verified?(
      auth(provider: "openid_connect", info: { email_verified: false }, extra: { raw_info: { "xms_edov" => true } })
    )
  end

  test "trusts a provider opted in with treat_email_as_verified" do
    assert SsoEmailVerification.verified?(auth(provider: "corp_oidc"))
    assert_not SsoEmailVerification.verified?(auth(provider: "off_oidc"))
    assert_not SsoEmailVerification.verified?(auth(provider: "corp_oidc", email: nil))
  end

  test "trusts the email a SAML IdP asserts" do
    assert SsoEmailVerification.verified?(auth(provider: "corp_saml"))
  end
end
