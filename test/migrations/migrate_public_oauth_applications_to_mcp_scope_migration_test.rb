# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261023000000_migrate_public_oauth_applications_to_mcp_scope")

class MigratePublicOauthApplicationsToMcpScopeMigrationTest < ActiveSupport::TestCase
  setup do
    @legacy_app = create_application(scopes: "read_write", confidential: false)
  end

  test "moves a public read_write application to mcp without replacing its registration" do
    registration = @legacy_app.attributes.except("scopes", "updated_at")

    run_migration

    assert_equal "mcp:read_write", @legacy_app.reload.scopes.to_s
    assert_equal registration, @legacy_app.attributes.except("scopes", "updated_at")
  end

  test "leaves confidential applications and other scope combinations unchanged" do
    applications = [
      create_application(scopes: "read_write", confidential: true),
      create_application(scopes: "read", confidential: false),
      create_application(scopes: "mcp:read_write", confidential: false),
      create_application(scopes: "read read_write", confidential: false)
    ]
    original_attributes = applications.map(&:attributes)

    run_migration

    assert_equal original_attributes, applications.map { |app| app.reload.attributes }
  end

  test "preserves existing tokens and authorization grants during the transition" do
    token = Doorkeeper::AccessToken.create!( # pipelock:ignore
      application: @legacy_app,
      resource_owner_id: users(:family_admin).id,
      scopes: "read_write",
      expires_in: 1.year,
      use_refresh_token: true
    )
    grant = Doorkeeper::AccessGrant.create!(
      application: @legacy_app,
      resource_owner_id: users(:family_admin).id,
      redirect_uri: @legacy_app.redirect_uri,
      scopes: "read_write",
      expires_in: 10.minutes
    )
    token_attributes = token.attributes
    grant_attributes = grant.attributes

    run_migration

    assert_equal token_attributes, token.reload.attributes
    assert_equal grant_attributes, grant.reload.attributes
  end

  test "can be run again without changing an already migrated application" do
    run_migration
    migrated_attributes = @legacy_app.reload.attributes

    run_migration

    assert_equal migrated_attributes, @legacy_app.reload.attributes
  end

  test "refuses to restore broad API scopes on rollback" do
    assert_raises ActiveRecord::IrreversibleMigration do
      ActiveRecord::Migration.suppress_messages { MigratePublicOauthApplicationsToMcpScope.new.down }
    end
  end

  private

    def create_application(scopes:, confidential:)
      Doorkeeper::Application.create!(
        name: "Migration Client #{SecureRandom.hex(4)}",
        redirect_uri: "https://claude.ai/callback",
        scopes: scopes,
        confidential: confidential
      )
    end

    def run_migration
      ActiveRecord::Migration.suppress_messages { MigratePublicOauthApplicationsToMcpScope.new.up }
    end
end
