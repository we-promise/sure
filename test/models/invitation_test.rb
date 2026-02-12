require "test_helper"

class InvitationTest < ActiveSupport::TestCase
  setup do
    @invitation = invitations(:one)
    @family = @invitation.family
    @inviter = @invitation.inviter
  end

  test "accept_for creates membership when email matches" do
    user = users(:empty)
    original_family_id = user.family_id
    assert original_family_id != @family.id

    invitation = @family.invitations.create!(email: user.email, role: "member", inviter: @inviter)
    assert invitation.pending?

    assert_difference "Membership.count", 1 do
      result = invitation.accept_for(user)
      assert result
    end

    # User keeps their original family_id (not overwritten)
    user.reload
    assert_equal original_family_id, user.family_id

    # But a membership was created for the new family
    membership = user.membership_for(@family)
    assert_not_nil membership
    assert_equal "member", membership.role

    invitation.reload
    assert invitation.accepted_at.present?
  end

  test "accept_for returns false when user email does not match" do
    user = users(:family_member)
    assert user.email != @invitation.email

    assert_no_difference "Membership.count" do
      result = @invitation.accept_for(user)
      assert_not result
    end

    @invitation.reload
    assert_nil @invitation.accepted_at
  end

  test "accept_for updates membership role when user already has membership in family" do
    user = users(:family_member)
    existing_membership = user.membership_for(@family)
    assert_equal "member", existing_membership.role

    invitation = @family.invitations.create!(email: user.email, role: "admin", inviter: @inviter)

    assert_no_difference "Membership.count" do
      result = invitation.accept_for(user)
      assert result
    end

    existing_membership.reload
    assert_equal "admin", existing_membership.role
    invitation.reload
    assert invitation.accepted_at.present?
  end

  test "accept_for returns false when invitation not pending" do
    @invitation.update!(accepted_at: 1.hour.ago)
    user = users(:empty)

    result = @invitation.accept_for(user)

    assert_not result
  end

  test "accept_for preserves existing memberships in other families" do
    user = users(:empty)
    original_family = user.family
    original_membership = user.membership_for(original_family)
    assert_not_nil original_membership

    invitation = @family.invitations.create!(email: user.email, role: "member", inviter: @inviter)
    invitation.accept_for(user)

    # Original membership still exists
    assert_not_nil user.membership_for(original_family)
    # New membership was created
    assert_not_nil user.membership_for(@family)
    # User now has 2 memberships
    assert_equal 2, user.memberships.count
  end
end
