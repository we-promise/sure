require "test_helper"

class InvitationTest < ActiveSupport::TestCase
  setup do
    @invitation = invitations(:one)
    @family = @invitation.family
    @inviter = @invitation.inviter
  end

  test "accept_for adds user to family when email matches" do
    user = users(:empty)
    user.update_columns(family_id: families(:empty).id, role: "admin")
    assert user.family_id != @family.id

    invitation = @family.invitations.create!(email: user.email, role: "member", inviter: @inviter)
    assert invitation.pending?
    result = invitation.accept_for(user)

    assert result
    user.reload
    assert_equal @family.id, user.family_id
    assert_equal "member", user.role
    invitation.reload
    assert invitation.accepted_at.present?
  end

  test "accept_for returns false when user email does not match" do
    user = users(:family_member)
    assert user.email != @invitation.email

    result = @invitation.accept_for(user)

    assert_not result
    user.reload
    assert_equal families(:dylan_family).id, user.family_id
    @invitation.reload
    assert_nil @invitation.accepted_at
  end

  test "accept_for updates role when user already in family" do
    user = users(:family_member)
    user.update!(family_id: @family.id, role: "member")
    invitation = @family.invitations.create!(email: user.email, role: "admin", inviter: @inviter)
    original_family_id = user.family_id

    result = invitation.accept_for(user)

    assert result
    user.reload
    assert_equal original_family_id, user.family_id
    assert_equal "admin", user.role
    invitation.reload
    assert invitation.accepted_at.present?
  end

  test "accept_for returns false when invitation not pending" do
    @invitation.update!(accepted_at: 1.hour.ago)
    user = users(:empty)

    result = @invitation.accept_for(user)

    assert_not result
  end

  test "accept_for applies guest role defaults" do
    user = users(:family_member)
    user.update!(
      family_id: @family.id,
      role: "member",
      ui_layout: "dashboard",
      show_sidebar: true,
      show_ai_sidebar: true,
      ai_enabled: false
    )
    invitation = @family.invitations.create!(email: user.email, role: "guest", inviter: @inviter)

    result = invitation.accept_for(user)

    assert result
    user.reload
    assert_equal "guest", user.role
    assert user.ui_layout_intro?
    assert_not user.show_sidebar?
    assert_not user.show_ai_sidebar?
    assert user.ai_enabled?
  end
end
