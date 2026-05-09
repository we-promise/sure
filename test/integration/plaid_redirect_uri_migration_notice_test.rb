require "test_helper"

# Integration test for the production-registered Plaid OAuth redirect URI
# MigrationNotice. Lives separately from MigrationNoticeTest because that
# suite resets the registry between examples; here we want to exercise the
# notice as it's registered at boot in config/initializers/migration_notices.rb.
class PlaidRedirectUriMigrationNoticeTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @notice = MigrationNotice.all.find { |n| n.key == "plaid_oauth_redirect_uri" }
    refute_nil @notice, "Plaid OAuth redirect URI notice must be registered at boot"
  end

  test "condition is false when the family has no Plaid connections" do
    refute @notice.condition.call(@family)
  end

  test "condition is false for a fresh-install Plaid connection (no migrated_from_legacy flag)" do
    @family.provider_connections.create!(
      provider_key: "plaid", auth_type: "embedded_link",
      status: :healthy,
      credentials: { "access_token" => "tok" },
      metadata:    { "region" => "us" }
    )
    refute @notice.condition.call(@family),
      "fresh installs that set up Plaid via the new flow shouldn't see the redirect-URI warning"
  end

  test "condition is true for a connection that came from MigrateLegacyPlaidToFramework" do
    @family.provider_connections.create!(
      provider_key: "plaid", auth_type: "embedded_link",
      status: :healthy,
      credentials: { "access_token" => "tok" },
      metadata: {
        "region" => "us",
        "migrated_from_legacy" => true,
        "plaid_item_id" => "item_legacy_xyz"
      }
    )
    assert @notice.condition.call(@family),
      "operators upgrading from legacy Plaid must see the redirect-URI warning"
  end

  test "condition is false when migrated_from_legacy is explicitly false" do
    @family.provider_connections.create!(
      provider_key: "plaid", auth_type: "embedded_link",
      status: :healthy,
      credentials: { "access_token" => "tok" },
      metadata: { "region" => "us", "migrated_from_legacy" => false }
    )
    refute @notice.condition.call(@family)
  end
end
