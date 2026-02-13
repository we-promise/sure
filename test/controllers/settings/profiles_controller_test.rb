require "test_helper"

class Settings::ProfilesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:family_admin)
    @member = users(:family_member)
    @intro_user = users(:intro_user)
  end

  test "should get show" do
    sign_in @admin
    get settings_profile_path
    assert_response :success
  end

  test "intro user sees profile without settings navigation" do
    sign_in @intro_user
    get settings_profile_path

    assert_response :success
    assert_select "#mobile-settings-nav", count: 0
    assert_select "h2", text: I18n.t("settings.profiles.show.household_title"), count: 0
    assert_select "[data-action='app-layout#openMobileSidebar']", count: 0
    assert_select "[data-action='app-layout#closeMobileSidebar']", count: 0
    assert_select "[data-action='app-layout#toggleLeftSidebar']", count: 0
    assert_select "[data-action='app-layout#toggleRightSidebar']", count: 0
  end

  test "admin can remove a family member" do
    sign_in @admin
    assert_difference("User.count", -1) do
      delete settings_profile_path(user_id: @member)
    end

    assert_redirected_to settings_profile_path
    assert_equal "Member removed successfully.", flash[:notice]
    assert_raises(ActiveRecord::RecordNotFound) { User.find(@member.id) }
  end

  test "admin cannot remove themselves" do
    sign_in @admin
    assert_no_difference("User.count") do
      delete settings_profile_path(user_id: @admin)
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("settings.profiles.destroy.cannot_remove_self"), flash[:alert]
    assert User.find(@admin.id)
  end

  test "non-admin cannot remove members" do
    sign_in @member
    assert_no_difference("User.count") do
      delete settings_profile_path(user_id: @admin)
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("settings.profiles.destroy.not_authorized"), flash[:alert]
    assert User.find(@admin.id)
  end

  test "admin removing a family member also destroys their invitation" do
    # Create an invitation for the member
    invitation = @admin.family.invitations.create!(
      email: @member.email,
      role: "member",
      inviter: @admin
    )

    sign_in @admin

    assert_difference [ "User.count", "Invitation.count" ], -1 do
      delete settings_profile_path(user_id: @member)
    end

    assert_redirected_to settings_profile_path
    assert_equal "Member removed successfully.", flash[:notice]
    assert_raises(ActiveRecord::RecordNotFound) { User.find(@member.id) }
    assert_raises(ActiveRecord::RecordNotFound) { Invitation.find(invitation.id) }
  end

  test "removing member restores them to preserved family if exists" do
    # Create a preserved family scenario
    # 1. Create a user with their own family
    preserved_family = Family.create!(name: "Preserved Family", currency: "USD")
    user = User.create!(
      email: "restored@example.com",
      password: "password123",
      family: preserved_family,
      role: "admin",
      first_name: "Restored",
      last_name: "User"
    )
    
    # 2. Simulate invitation acceptance that created a preserved user
    preserved_user = User.create!(
      email: "restored+family#{preserved_family.id}@example.com",
      password: SecureRandom.hex(32),
      family: preserved_family,
      role: "admin",
      first_name: "Restored",
      last_name: "User"
    )
    preserved_user.skip_password_validation = true
    preserved_user.save!
    
    # 3. Move user to admin's family (simulating accepted invitation)
    user.update!(family: @admin.family, role: "member")
    
    # At this point:
    # - preserved_family has 1 user (preserved_user)
    # - admin.family has multiple users including user
    
    # 4. Now remove the user from admin's family
    sign_in @admin
    
    # User is moved back to preserved_family and preserved_user is destroyed
    # Net result: User.count decreases by 1 (preserved_user is deleted)
    assert_difference("User.count", -1) do
      delete settings_profile_path(user_id: user)
    end
    
    # User should be restored to their preserved family
    user.reload
    assert_equal preserved_family.id, user.family_id
    assert_equal "admin", user.role
    assert_redirected_to settings_profile_path
    assert_equal "Member removed and restored to their previous household.", flash[:notice]
    
    # Preserved family should still have 1 user (the restored user, not the preserved user)
    preserved_family.reload
    assert_equal 1, preserved_family.users.count
    assert_equal user.id, preserved_family.users.first.id
    
    # Preserved user should be gone
    assert_raises(ActiveRecord::RecordNotFound) { User.find(preserved_user.id) }
  end
end
