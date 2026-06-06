require "test_helper"

class InvitationTest < ActiveSupport::TestCase
  setup do
    @invitation = invitations(:one)
    @family = @invitation.family
    @inviter = @invitation.inviter
  end

  test "accept_for adds membership without moving an existing user to another family" do
    user = users(:empty)
    original_family_id = user.family_id
    original_role = user.role
    invitation = @family.invitations.create!(email: user.email, role: "member", inviter: @inviter)

    assert_difference("FamilyMembership.count", 1) do
      result = invitation.accept_for(user)

      assert result
    end

    user.reload
    assert_equal original_family_id, user.family_id
    assert_equal original_role, user.role
    assert FamilyMembership.exists?(user: user, family: @family)
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

    # 2D: always find_or_create membership — if none exists, it creates one
    result = invitation.accept_for(user)
    assert result

    user.reload
    assert_equal original_family_id, user.family_id
    assert_equal "admin", user.role

    membership = user.membership_for(@family)
    assert_not_nil membership, "should create a membership for the invited role"
    assert_equal "admin", membership.role

    invitation.reload
    assert invitation.accepted_at.present?
  end

  test "accept_for returns false when invitation not pending" do
    @invitation.update!(accepted_at: 1.hour.ago)
    user = users(:empty)

    result = @invitation.accept_for(user)

    assert_not result
  end

  test "cannot create invitation when email has pending invitation from another family" do
    other_family = families(:empty)
    other_inviter = users(:empty)
    other_inviter.update_columns(family_id: other_family.id, role: "admin")

    email = "cross-family-test@example.com"

    # Create a pending invitation in the first family
    @family.invitations.create!(email: email, role: "member", inviter: @inviter)

    # Attempting to create a pending invitation in a different family should fail
    invitation = other_family.invitations.build(email: email, role: "member", inviter: other_inviter)
    assert_not invitation.valid?
    assert_includes invitation.errors[:email], "already has a pending invitation from another family"
  end

  test "can create invitation when existing invitation from another family is accepted" do
    other_family = families(:empty)
    other_inviter = users(:empty)
    other_inviter.update_columns(family_id: other_family.id, role: "admin")

    email = "cross-family-accepted@example.com"

    # Create an accepted invitation in the first family
    accepted_invitation = @family.invitations.create!(email: email, role: "member", inviter: @inviter)
    accepted_invitation.update!(accepted_at: Time.current)

    # Should be able to create a pending invitation in a different family
    invitation = other_family.invitations.build(email: email, role: "member", inviter: other_inviter)
    assert invitation.valid?
  end

  test "can create invitation when existing invitation from another family is expired" do
    other_family = families(:empty)
    other_inviter = users(:empty)
    other_inviter.update_columns(family_id: other_family.id, role: "admin")

    email = "cross-family-expired@example.com"

    # Create an expired invitation in the first family
    expired_invitation = @family.invitations.create!(email: email, role: "member", inviter: @inviter)
    expired_invitation.update_columns(expires_at: 1.day.ago)

    # Should be able to create a pending invitation in a different family
    invitation = other_family.invitations.build(email: email, role: "member", inviter: other_inviter)
    assert invitation.valid?
  end

  test "can create invitation in same family (uniqueness scoped to family)" do
    email = "same-family-test@example.com"

    # Create a pending invitation in the family
    @family.invitations.create!(email: email, role: "member", inviter: @inviter)

    # Attempting to create another in the same family should fail due to the existing scope validation
    invitation = @family.invitations.build(email: email, role: "admin", inviter: @inviter)
    assert_not invitation.valid?
    assert_includes invitation.errors[:email], "has already been invited to this family"
  end

  test "accept_for refuses when invitee owns accounts that would be orphaned" do
    owner = users(:empty)
    owner_family = families(:empty)
    owner.update_columns(family_id: owner_family.id, role: "admin")
    account = owner_family.accounts.create!(
      name: "Prior savings", balance: 100, currency: "USD",
      accountable: Depository.new
    )
    account.update_columns(owner_id: owner.id)

    invitation = @family.invitations.create!(email: owner.email, role: "member", inviter: @inviter)

    assert_difference("FamilyMembership.count", 1) do
      result = invitation.accept_for(owner)

      assert result, "existing users should join another family without being rehomed"
    end

    owner.reload
    assert_equal owner_family.id, owner.family_id, "user.family_id must remain unchanged"
    assert FamilyMembership.exists?(user: owner, family: @family)
    invitation.reload
    assert invitation.accepted_at.present?
    assert owner_family.accounts.exists?, "original family's accounts must remain intact"
  end

  test "accept_for allows a member who owns no accounts to join another family" do
    member = users(:empty)
    other_owner = users(:sure_support_staff)
    source_family = families(:empty)
    member.update_columns(family_id: source_family.id, role: "member")
    other_owner.update_columns(family_id: source_family.id, role: "admin")
    account = source_family.accounts.create!(
      name: "Shared savings", balance: 100, currency: "USD",
      accountable: Depository.new
    )
    account.update_columns(owner_id: other_owner.id)

    invitation = @family.invitations.create!(email: member.email, role: "member", inviter: @inviter)

    assert_difference("FamilyMembership.count", 1) do
      result = invitation.accept_for(member)

      assert result, "a non-owner member must be free to join another family"
    end

    member.reload
    assert_equal source_family.id, member.family_id
    assert FamilyMembership.exists?(user: member, family: @family)
  end

  test "would_orphan_owned_accounts? is false when invitee owns no accounts" do
    user = users(:empty)
    user.update_columns(family_id: families(:empty).id, role: "admin")
    invitation = @family.invitations.create!(email: user.email, role: "member", inviter: @inviter)

    assert_not invitation.would_orphan_owned_accounts?(user)
  end

  test "would_orphan_owned_accounts? is false when invitee owns accounts in another family" do
    user = users(:empty)
    source_family = families(:empty)
    user.update_columns(family_id: source_family.id, role: "admin")
    account = source_family.accounts.create!(
      name: "Legacy savings", balance: 100, currency: "USD",
      accountable: Depository.new
    )
    account.update_columns(owner_id: user.id)
    invitation = @family.invitations.create!(email: user.email, role: "member", inviter: @inviter)

    assert_not invitation.would_orphan_owned_accounts?(user)
  end

  test "would_orphan_owned_accounts? is false when same-family role change" do
    user = users(:family_member)
    user.update!(family_id: @family.id, role: "member")
    invitation = @family.invitations.create!(email: user.email, role: "admin", inviter: @inviter)

    assert_not invitation.would_orphan_owned_accounts?(user)
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
