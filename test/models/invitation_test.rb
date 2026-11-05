require "test_helper"

class InvitationTest < ActiveSupport::TestCase
  setup do
    @invitation = invitations(:one)
    @family = @invitation.family
    @inviter = @invitation.inviter
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

  test "re-inviting an email with an expired unaccepted invitation replaces it without raising" do
    email = "expired-reinvite@example.com"

    expired = @family.invitations.create!(email: email, role: "member", inviter: @inviter)
    expired.update_column(:expires_at, 1.day.ago)

    invitation = nil
    assert_nothing_raised do
      invitation = @family.invitations.create!(email: email, role: "admin", inviter: @inviter)
    end

    assert invitation.pending?
    assert_not Invitation.exists?(expired.id), "stale expired invitation should be removed"
    assert_equal 1, @family.invitations.where(email: email).count
  end

  test "re-invite does not remove a still-pending duplicate (validation blocks first)" do
    email = "still-pending@example.com"
    pending = @family.invitations.create!(email: email, role: "member", inviter: @inviter)

    duplicate = @family.invitations.build(email: email, role: "admin", inviter: @inviter)
    assert_not duplicate.valid?

    assert Invitation.exists?(pending.id), "an unexpired pending invitation must be preserved"
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

  test "email_registered? matches existing accounts regardless of case" do
    assert @family.invitations.build(email: users(:family_member).email.upcase).email_registered?
    assert_not @family.invitations.build(email: "nobody-yet@example.com").email_registered?
  end

  test "an email that already belongs to an account can be invited like any other" do
    invitation = @family.invitations.build(email: users(:empty).email, role: "member", inviter: @inviter)

    assert invitation.valid?
  end
end
