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

  test "admin can remove a family member by destroying their membership" do
    sign_in @admin
    family = @admin.family
    membership = @member.membership_for(family)
    assert_not_nil membership

    assert_difference("Membership.count", -1) do
      delete settings_profile_path(user_id: @member)
    end

    assert_redirected_to settings_profile_path
    assert_nil @member.reload.membership_for(family)
  end

  test "removing a member with no other memberships triggers user purge" do
    sign_in @admin
    # Member only has one membership (in dylan_family)
    assert_equal 1, @member.memberships.count

    assert_difference("Membership.count", -1) do
      delete settings_profile_path(user_id: @member)
    end

    assert_redirected_to settings_profile_path
    # User purge is enqueued via purge_later
    assert_enqueued_with(job: UserPurgeJob)
  end

  test "removing a member with other memberships does not purge user" do
    sign_in @admin
    # Give member a second membership in another family
    other_family = families(:empty)
    Membership.create!(user: @member, family: other_family, role: "member")
    assert_equal 2, @member.memberships.count

    assert_difference("Membership.count", -1) do
      delete settings_profile_path(user_id: @member)
    end

    assert_redirected_to settings_profile_path
    # User should still exist since they have another membership
    assert User.find(@member.id)
    assert_equal 1, @member.memberships.reload.count
  end

  test "admin cannot remove themselves" do
    sign_in @admin
    assert_no_difference("Membership.count") do
      delete settings_profile_path(user_id: @admin)
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("settings.profiles.destroy.cannot_remove_self"), flash[:alert]
    assert User.find(@admin.id)
  end

  test "non-admin cannot remove members" do
    sign_in @member
    assert_no_difference("Membership.count") do
      delete settings_profile_path(user_id: @admin)
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("settings.profiles.destroy.not_authorized"), flash[:alert]
    assert User.find(@admin.id)
  end

  test "admin removing a family member also destroys their invitation" do
    invitation = @admin.family.invitations.create!(
      email: @member.email,
      role: "member",
      inviter: @admin
    )

    sign_in @admin

    assert_difference("Invitation.count", -1) do
      assert_difference("Membership.count", -1) do
        delete settings_profile_path(user_id: @member)
      end
    end

    assert_redirected_to settings_profile_path
    assert_raises(ActiveRecord::RecordNotFound) { Invitation.find(invitation.id) }
  end
end
