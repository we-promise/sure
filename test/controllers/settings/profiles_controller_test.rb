require "test_helper"

class Settings::ProfilesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:family_admin)
    @member = users(:family_member)
    @intro_user = users(:intro_user)

    FamilyMembership.find_or_create_by!(user: @admin, family: @admin.family)
    FamilyMembership.find_or_create_by!(user: @member, family: @member.family)
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

  test "should show members that belong via membership" do
    sign_in @admin

    membership_user = users(:empty)
    FamilyMembership.create!(user: membership_user, family: @admin.family)

    get settings_profile_path

    assert_response :success
    assert_select "p.text-primary", text: membership_user.display_name
  end

  test "admin can remove a family membership without deleting the user" do
    sign_in @admin

    member = users(:empty)
    account = member.family.accounts.create!(
      name: "Legacy savings", balance: 250, currency: "USD",
      accountable: Depository.new
    )
    account.update_columns(owner_id: member.id)
    FamilyMembership.create!(user: member, family: @admin.family)
    membership = @admin.family.family_memberships.find_by!(user: member)
    invitation = @admin.family.invitations.create!(
      email: member.email,
      role: "member",
      inviter: @admin
    )

    assert_difference("FamilyMembership.count", -1) do
      assert_no_difference("User.count") do
        delete settings_profile_path(membership_id: membership.id)
      end
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("settings.profiles.destroy.member_removed"), flash[:notice]
    assert User.find(member.id)
    assert Account.exists?(account.id)
    assert_raises(ActiveRecord::RecordNotFound) { Invitation.find(invitation.id) }
  end

  test "admin cannot remove a member who owns accounts in this household" do
    sign_in @admin

    member = users(:empty)
    account = @admin.family.accounts.create!(
      name: "Joint checking", balance: 500, currency: "USD",
      accountable: Depository.new
    )
    account.update_columns(owner_id: member.id)
    FamilyMembership.create!(user: member, family: @admin.family)
    membership = @admin.family.family_memberships.find_by!(user: member)

    assert_no_difference("FamilyMembership.count") do
      assert_no_difference("User.count") do
        delete settings_profile_path(membership_id: membership.id)
      end
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("settings.profiles.destroy.member_owns_household_data"), flash[:alert]
    assert User.find(member.id)
    assert Account.exists?(account.id)
  end

  test "admin cannot remove themselves" do
    sign_in @admin
    membership = @admin.family.family_memberships.find_by!(user: @admin)

    assert_no_difference("User.count") do
      delete settings_profile_path(membership_id: membership.id)
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("settings.profiles.destroy.cannot_remove_self"), flash[:alert]
    assert User.find(@admin.id)
  end

  test "non-admin cannot remove members" do
    sign_in @member
    membership = @admin.family.family_memberships.find_by!(user: @admin)

    assert_no_difference("User.count") do
      delete settings_profile_path(membership_id: membership.id)
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("settings.profiles.destroy.not_authorized"), flash[:alert]
    assert User.find(@admin.id)
  end

  test "admin can remove a member who owns accounts in another family" do
    other_family = families(:empty)
    legacy_account = other_family.accounts.create!(
      name: "Legacy savings", balance: 250, currency: "USD",
      accountable: Depository.new
    )
    legacy_account.update_columns(owner_id: @member.id)
    FamilyMembership.create!(user: @member, family: @admin.family)
    membership = @admin.family.family_memberships.find_by!(user: @member)

    sign_in @admin

    assert_difference("FamilyMembership.count", -1) do
      assert_no_difference("User.count") do
        delete settings_profile_path(membership_id: membership.id)
      end
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("settings.profiles.destroy.member_removed"), flash[:notice]
    assert User.find(@member.id), "user row must be preserved so historical access can be restored"
    assert Account.exists?(legacy_account.id)
  end

  test "admin removing a family member also destroys their invitation" do
    invitation = @admin.family.invitations.create!(
      email: @member.email,
      role: "member",
      inviter: @admin
    )
    FamilyMembership.create!(user: @member, family: @admin.family)
    membership = @admin.family.family_memberships.find_by!(user: @member)

    sign_in @admin

    assert_difference([ "FamilyMembership.count", "Invitation.count" ], -1) do
      assert_no_difference("User.count") do
        delete settings_profile_path(membership_id: membership.id)
      end
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("settings.profiles.destroy.member_removed"), flash[:notice]
    assert User.find(@member.id)
    assert_raises(ActiveRecord::RecordNotFound) { Invitation.find(invitation.id) }
  end
end
