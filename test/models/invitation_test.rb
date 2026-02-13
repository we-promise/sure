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

  test "accept_for preserves old family when user is only member" do
    # Create a user with their own family
    new_family = Family.create!(name: "Test Family", currency: "USD")
    user = User.create!(
      email: "solo@example.com",
      password: "password123",
      family: new_family,
      role: "admin",
      first_name: "Solo",
      last_name: "User"
    )
    
    # Verify user is the only member of their family
    assert_equal 1, new_family.users.count
    old_family_id = user.family_id
    
    # Create invitation to a different family
    invitation = @family.invitations.create!(
      email: user.email,
      role: "member",
      inviter: @inviter
    )
    
    # Accept the invitation
    assert_difference("User.count", 1) do # Should create a preserved user
      result = invitation.accept_for(user)
      assert result
    end
    
    # Original user should now be in the new family
    user.reload
    assert_equal @family.id, user.family_id
    assert_equal "member", user.role
    
    # Old family should still exist with a preserved user
    new_family.reload
    assert_equal 1, new_family.users.count
    preserved_user = new_family.users.first
    assert_equal "solo+family#{old_family_id}@example.com", preserved_user.email
    assert_equal "Solo", preserved_user.first_name
    assert_equal "User", preserved_user.last_name
  end

  test "accept_for does not preserve family when user is not only member" do
    # Create a family with multiple users
    multi_family = Family.create!(name: "Multi Family", currency: "USD")
    user1 = User.create!(
      email: "multi_user1_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      family: multi_family,
      role: "admin",
      first_name: "User",
      last_name: "One"
    )
    user2 = User.create!(
      email: "multi_user2_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      family: multi_family,
      role: "member",
      first_name: "User",
      last_name: "Two"
    )
    
    # Verify family has multiple users
    assert_equal 2, multi_family.users.count
    
    # Create invitation for user1 to join different family
    invitation = @family.invitations.create!(
      email: user1.email,
      role: "member",
      inviter: @inviter
    )
    
    # Accept the invitation - should NOT create a preserved user
    assert_no_difference("User.count") do
      result = invitation.accept_for(user1)
      assert result
    end
    
    # User1 should now be in the new family
    user1.reload
    assert_equal @family.id, user1.family_id
    
    # Old family should still exist with user2
    multi_family.reload
    assert_equal 1, multi_family.users.count
    assert_equal user2.id, multi_family.users.first.id
  end
end
