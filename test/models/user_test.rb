require "test_helper"

class UserTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def setup
    @user = users(:family_admin)
  end

  def teardown
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "should be valid" do
    assert @user.valid?, @user.errors.full_messages.to_sentence
  end

  # email
  test "email must be present" do
    potential_user = User.new(
      email: "david@davidbowie.com",
      password_digest: BCrypt::Password.create("password"),
      first_name: "David",
      last_name: "Bowie"
    )
    potential_user.email = "     "
    assert_not potential_user.valid?
  end

  test "has email address" do
    assert_equal "bob@bobdylan.com", @user.email
  end

  test "can update email" do
    @user.update(email: "new_email@example.com")
    assert_equal "new_email@example.com", @user.email
  end

  test "email addresses must be unique" do
    duplicate_user = @user.dup
    duplicate_user.email = @user.email.upcase
    @user.save
    assert_not duplicate_user.valid?
  end

  test "email address is normalized" do
    @user.update!(email: " UNIQUE-User@ExAMPle.CoM ")
    assert_equal "unique-user@example.com", @user.reload.email
  end

  test "display name" do
    user = User.new(email: "user@example.com")
    assert_equal "user@example.com", user.display_name
    user.first_name = "Bob"
    assert_equal "Bob", user.display_name
    user.last_name = "Dylan"
    assert_equal "Bob Dylan", user.display_name
  end

  test "initial" do
    user = User.new(email: "user@example.com")
    assert_equal "U", user.initial
    user.first_name = "Bob"
    assert_equal "B", user.initial
    user.first_name = nil
    user.last_name = "Dylan"
    assert_equal "D", user.initial
  end

  test "names are normalized" do
    @user.update!(first_name: "", last_name: "")
    assert_nil @user.first_name
    assert_nil @user.last_name

    @user.update!(first_name: " Bob ", last_name: " Dylan ")
    assert_equal "Bob", @user.first_name
    assert_equal "Dylan", @user.last_name
  end

  # MFA Tests
  test "setup_mfa! generates required fields" do
    user = users(:family_member)
    user.setup_mfa!

    assert user.otp_secret.present?
    assert_not user.otp_required?
    assert_empty user.otp_backup_codes
  end

  test "enable_mfa! enables MFA and generates backup codes" do
    user = users(:family_member)
    user.setup_mfa!
    user.enable_mfa!

    assert user.otp_required?
    assert_equal 8, user.otp_backup_codes.length
    assert user.otp_backup_codes.all? { |code| code.length == 8 }
  end

  test "disable_mfa! removes all MFA data" do
    user = users(:family_member)
    user.setup_mfa!
    user.enable_mfa!
    user.disable_mfa!

    assert_nil user.otp_secret
    assert_not user.otp_required?
    assert_empty user.otp_backup_codes
  end

  test "verify_otp? validates TOTP codes" do
    user = users(:family_member)
    user.setup_mfa!

    totp = ROTP::TOTP.new(user.otp_secret, issuer: "Sure Finances")
    valid_code = totp.now

    assert user.verify_otp?(valid_code)
    assert_not user.verify_otp?("invalid")
    assert_not user.verify_otp?("123456")
  end

  test "verify_otp? accepts backup codes" do
    user = users(:family_member)
    user.setup_mfa!
    user.enable_mfa!

    backup_code = user.otp_backup_codes.first
    assert user.verify_otp?(backup_code)

    # Backup code should be consumed
    assert_not user.otp_backup_codes.include?(backup_code)
    assert_equal 7, user.otp_backup_codes.length

    # Used backup code should not work again
    assert_not user.verify_otp?(backup_code)
  end

  test "provisioning_uri generates correct URI" do
    user = users(:family_member)
    user.setup_mfa!

    assert_match %r{otpauth://totp/}, user.provisioning_uri
    assert_match %r{secret=#{user.otp_secret}}, user.provisioning_uri
    assert_match %r{issuer=Sure}, user.provisioning_uri
  end

  test "ai_available? returns true when openai access token set in settings" do
    Rails.application.config.app_mode.stubs(:self_hosted?).returns(true)
    previous = Setting.openai_access_token
    with_env_overrides OPENAI_ACCESS_TOKEN: nil do
      Setting.openai_access_token = nil
      assert_not @user.ai_available?

      Setting.openai_access_token = "token"
      assert @user.ai_available?
    end
  ensure
    Setting.openai_access_token = previous
  end

  test "intro layout collapses sidebars and enables ai" do
    user = User.new(
      family: families(:empty),
      email: "intro-new@example.com",
      password: "Password1!",
      password_confirmation: "Password1!",
      role: :guest,
      ui_layout: :intro
    )

    assert user.save, user.errors.full_messages.to_sentence
    assert user.ui_layout_intro?
    assert_not user.show_sidebar?
    assert_not user.show_ai_sidebar?
    assert user.ai_enabled?
  end

  test "non-guest role cannot persist intro layout" do
    user = User.new(
      family: families(:empty),
      email: "dashboard-only@example.com",
      password: "Password1!",
      password_confirmation: "Password1!",
      role: :member,
      ui_layout: :intro
    )

    assert user.save, user.errors.full_messages.to_sentence
    assert user.ui_layout_dashboard?
  end

  test "upgrading guest role restores dashboard layout defaults" do
    user = users(:intro_user)
    user.update!(role: :member)
    user.reload

    assert user.ui_layout_dashboard?
    assert user.show_sidebar?
    assert user.show_ai_sidebar?
  end

  test "update_dashboard_preferences handles concurrent updates atomically" do
    @user.update!(preferences: {})

    # Simulate concurrent updates from multiple requests
    # Each thread collapses a different section simultaneously
    threads = []
    sections = %w[net_worth_chart outflows_donut cashflow_sankey balance_sheet]

    sections.each_with_index do |section, index|
      threads << Thread.new do
        # Small staggered delays to increase chance of race conditions
        sleep(index * 0.01)

        # Each thread loads its own instance and updates
        user = User.find(@user.id)
        user.update_dashboard_preferences({
          "collapsed_sections" => { section => true }
        })
      end
    end

    # Wait for all threads to complete
    threads.each(&:join)

    # Verify all updates persisted (no data loss from race conditions)
    @user.reload
    sections.each do |section|
      assert @user.dashboard_section_collapsed?(section),
        "Expected #{section} to be collapsed, but it was not. " \
        "Preferences: #{@user.preferences.inspect}"
    end

    # Verify all sections are in the preferences hash
    assert_equal sections.sort,
      @user.preferences.dig("collapsed_sections")&.keys&.sort,
      "Expected all sections to be in preferences"
  end

  test "update_dashboard_preferences merges nested hashes correctly" do
    @user.update!(preferences: {})

    # First update: collapse net_worth
    @user.update_dashboard_preferences({
      "collapsed_sections" => { "net_worth_chart" => true }
    })
    @user.reload

    assert @user.dashboard_section_collapsed?("net_worth_chart")
    assert_not @user.dashboard_section_collapsed?("outflows_donut")

    # Second update: collapse outflows (should preserve net_worth)
    @user.update_dashboard_preferences({
      "collapsed_sections" => { "outflows_donut" => true }
    })
    @user.reload

    assert @user.dashboard_section_collapsed?("net_worth_chart"),
      "First collapsed section should still be collapsed"
    assert @user.dashboard_section_collapsed?("outflows_donut"),
      "Second collapsed section should be collapsed"
  end

  test "update_dashboard_preferences handles section_order updates" do
    @user.update!(preferences: {})

    # Set initial order
    new_order = %w[outflows_donut net_worth_chart cashflow_sankey balance_sheet]
    @user.update_dashboard_preferences({ "section_order" => new_order })
    @user.reload

    assert_equal new_order, @user.dashboard_section_order
  end

  test "handles empty preferences gracefully for dashboard methods" do
    @user.update!(preferences: {})

    # dashboard_section_collapsed? should return false when key is missing
    assert_not @user.dashboard_section_collapsed?("net_worth_chart"),
      "Should return false when collapsed_sections key is missing"

    # dashboard_section_order should return default order when key is missing
    assert_equal %w[cashflow_sankey outflows_donut net_worth_chart balance_sheet],
      @user.dashboard_section_order,
      "Should return default order when section_order key is missing"

    # update_dashboard_preferences should work with empty preferences
    @user.update_dashboard_preferences({ "section_order" => %w[balance_sheet] })
    @user.reload

    assert_equal %w[balance_sheet], @user.preferences["section_order"]
  end

  test "handles empty preferences gracefully for reports methods" do
    @user.update!(preferences: {})

    # reports_section_collapsed? should return false when key is missing
    assert_not @user.reports_section_collapsed?("trends_insights"),
      "Should return false when reports_collapsed_sections key is missing"

    # reports_section_order should return default order when key is missing
    assert_equal %w[trends_insights transactions_breakdown],
      @user.reports_section_order,
      "Should return default order when reports_section_order key is missing"

    # update_reports_preferences should work with empty preferences
    @user.update_reports_preferences({ "reports_section_order" => %w[transactions_breakdown] })
    @user.reload

    assert_equal %w[transactions_breakdown], @user.preferences["reports_section_order"]
  end

  test "handles missing nested keys in preferences for collapsed sections" do
    @user.update!(preferences: { "section_order" => %w[cashflow] })

    # Should return false when collapsed_sections key is missing entirely
    assert_not @user.dashboard_section_collapsed?("net_worth_chart"),
      "Should return false when collapsed_sections key is missing"

    # Should return false when section_key is missing from collapsed_sections
    @user.update!(preferences: { "collapsed_sections" => {} })
    assert_not @user.dashboard_section_collapsed?("net_worth_chart"),
      "Should return false when section key is missing from collapsed_sections"
  end

  # SSO-only user security tests
  test "sso_only? returns true for user with OIDC identity and no password" do
    sso_user = users(:sso_only)
    assert_nil sso_user.password_digest
    assert sso_user.oidc_identities.exists?
    assert sso_user.sso_only?
  end

  test "sso_only? returns false for user with password and OIDC identity" do
    # family_admin has both password and OIDC identity
    assert @user.password_digest.present?
    assert @user.oidc_identities.exists?
    assert_not @user.sso_only?
  end

  test "sso_only? returns false for user with password but no OIDC identity" do
    user_without_oidc = users(:empty)
    assert user_without_oidc.password_digest.present?
    assert_not user_without_oidc.oidc_identities.exists?
    assert_not user_without_oidc.sso_only?
  end

  test "has_local_password? returns true when password_digest is present" do
    assert @user.has_local_password?
  end

  test "has_local_password? returns false when password_digest is nil" do
    sso_user = users(:sso_only)
    assert_not sso_user.has_local_password?
  end

  test "user can be created without password when skip_password_validation is true" do
    user = User.new(
      email: "newssuser@example.com",
      first_name: "New",
      last_name: "SSO User",
      skip_password_validation: true,
      family: families(:empty)
    )
    assert user.valid?, user.errors.full_messages.to_sentence
    assert user.save
    assert_nil user.password_digest
  end

  test "user requires password on create when skip_password_validation is false" do
    user = User.new(
      email: "needspassword@example.com",
      first_name: "Needs",
      last_name: "Password",
      family: families(:empty)
    )
    assert_not user.valid?
    assert_includes user.errors[:password], "can't be blank"
  end

  # First user role assignment tests
  test "role_for_new_family_creator returns super_admin when no users exist" do
    # Delete all users to simulate fresh instance
    User.destroy_all

    assert_equal :super_admin, User.role_for_new_family_creator
  end

  test "role_for_new_family_creator returns fallback role when users exist" do
    # Users exist from fixtures
    assert User.exists?

    assert_equal :admin, User.role_for_new_family_creator
    assert_equal :member, User.role_for_new_family_creator(fallback_role: :member)
    assert_equal "custom_role", User.role_for_new_family_creator(fallback_role: "custom_role")
  end

  # ActiveStorage attachment cleanup tests
  test "purging a user removes attached profile image" do
    user = users(:family_admin)
    user.profile_image.attach(
      io: StringIO.new("profile-image-data"),
      filename: "profile.png",
      content_type: "image/png"
    )

    attachment_id = user.profile_image.id
    assert ActiveStorage::Attachment.exists?(attachment_id)

    perform_enqueued_jobs do
      user.purge
    end

    assert_not User.exists?(user.id)
    assert_not ActiveStorage::Attachment.exists?(attachment_id)
  end

  test "purging the last user cascades to remove family and its export attachments" do
    family = Family.create!(name: "Solo Family", locale: "en", date_format: "%m-%d-%Y", currency: "USD")
    user = User.create!(family: family, email: "solo@example.com", password: "password123")
    export = family.family_exports.create!
    export.export_file.attach(
      io: StringIO.new("export-data"),
      filename: "export.zip",
      content_type: "application/zip"
    )

    export_attachment_id = export.export_file.id
    assert ActiveStorage::Attachment.exists?(export_attachment_id)

    perform_enqueued_jobs do
      user.purge
    end

    assert_not Family.exists?(family.id)
    assert_not ActiveStorage::Attachment.exists?(export_attachment_id)
  end
end
