require "test_helper"

class InvitationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @admin = users(:family_admin)
    @invitation = invitations(:one)
  end

  test "should get new" do
    get new_invitation_url
    assert_response :success
    assert_select "option[value=?]", "member"
    assert_select "option[value=?]", "admin"
  end

  test "should create invitation for member" do
    Rails.application.config.stubs(:app_mode).returns("managed".inquiry)

    assert_difference("Invitation.count") do
      assert_enqueued_with(job: ActionMailer::MailDeliveryJob) do
        post invitations_url, params: {
          invitation: {
            email: "new@example.com",
            role: "member"
          }
        }
      end
    end

    invitation = Invitation.order(created_at: :desc).first
    assert_equal "member", invitation.role
    assert_equal @admin, invitation.inviter
    assert_equal "new@example.com", invitation.email
    assert_redirected_to settings_profile_path
    assert_equal I18n.t("invitations.create.success"), flash[:notice]
  end

  test "should add existing user to household when inviting their email" do
    existing_user = users(:empty)
    old_family = existing_user.family
    old_family_id = existing_user.family_id
    
    # Ensure the user is alone in their family for preservation to trigger
    old_family.users.where.not(id: existing_user.id).destroy_all
    assert_equal 1, old_family.users.count, "User should be alone in their family"
    assert existing_user.family_id != @admin.family_id

    assert_difference("Invitation.count") do
      assert_difference("User.count", 1) do # Should create preserved user
        assert_no_enqueued_jobs only: ActionMailer::MailDeliveryJob do
          post invitations_url, params: {
            invitation: {
              email: existing_user.email,
              role: "member"
            }
          }
        end
      end
    end

    invitation = Invitation.order(created_at: :desc).first
    assert invitation.accepted_at.present?, "Invitation should be accepted"
    existing_user.reload
    assert_equal @admin.family_id, existing_user.family_id
    assert_equal "member", existing_user.role
    assert_redirected_to settings_profile_path
    
    # Should show warning since user switched families
    assert_equal I18n.t("invitations.create.existing_user_added_with_warning"), flash[:notice]
    
    # Verify preserved user was created with correct email pattern
    preserved_email = "#{existing_user.email.split('@')[0]}+family#{old_family_id}@#{existing_user.email.split('@')[1]}"
    preserved_user = User.find_by(email: preserved_email)
    assert_not_nil preserved_user, "Preserved user should have been created"
    assert_equal old_family_id, preserved_user.family_id
  end

  test "should show regular message when user is already in same family" do
    # Create a user already in the admin's family
    existing_user = User.create!(
      email: "samefamily@example.com",
      password: "password123",
      family: @admin.family,
      role: "member",
      first_name: "Same",
      last_name: "Family"
    )

    assert_difference("Invitation.count") do
      # Should NOT create a preserved user since user is in same family
      assert_no_difference("User.count") do
        post invitations_url, params: {
          invitation: {
            email: existing_user.email,
            role: "admin"
          }
        }
      end
    end

    existing_user.reload
    assert_equal @admin.family_id, existing_user.family_id
    assert_equal "admin", existing_user.role
    assert_redirected_to settings_profile_path
    # Should show regular message since user stayed in same family
    assert_equal I18n.t("invitations.create.existing_user_added"), flash[:notice]
    
    # Verify no preserved user was created
    assert_nil User.find_by("email LIKE ?", "%+family%"), "No preserved user should be created for same-family invitation"
  end

  test "non-admin cannot create invitations" do
    sign_in users(:family_member)

    assert_no_difference("Invitation.count") do
      post invitations_url, params: {
        invitation: {
          email: "new@example.com",
          role: "admin"
        }
      }
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("invitations.create.failure"), flash[:alert]
  end

  test "admin can create admin invitation" do
    assert_difference("Invitation.count") do
      post invitations_url, params: {
        invitation: {
          email: "new@example.com",
          role: "admin"
        }
      }
    end

    invitation = Invitation.order(created_at: :desc).first
    assert_equal "admin", invitation.role
    assert_equal @admin.family, invitation.family
    assert_equal @admin, invitation.inviter
  end

  test "admin can create guest invitation" do
    assert_difference("Invitation.count") do
      post invitations_url, params: {
        invitation: {
          email: "intro-invite@example.com",
          role: "guest"
        }
      }
    end

    invitation = Invitation.order(created_at: :desc).first
    assert_equal "guest", invitation.role
    assert_equal @admin.family, invitation.family
    assert_equal @admin, invitation.inviter
  end

  test "inviting an existing user as guest applies intro defaults" do
    existing_user = users(:empty)
    existing_user.update!(
      role: :member,
      ui_layout: :dashboard,
      show_sidebar: true,
      show_ai_sidebar: true,
      ai_enabled: false
    )

    assert_difference("Invitation.count") do
      post invitations_url, params: {
        invitation: {
          email: existing_user.email,
          role: "guest"
        }
      }
    end

    existing_user.reload
    assert_equal "guest", existing_user.role
    assert existing_user.ui_layout_intro?
    assert_not existing_user.show_sidebar?
    assert_not existing_user.show_ai_sidebar?
    assert existing_user.ai_enabled?
  end

  test "should handle invalid invitation creation" do
    assert_no_difference("Invitation.count") do
      post invitations_url, params: {
        invitation: {
          email: "",
          role: "member"
        }
      }
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("invitations.create.failure"), flash[:alert]
  end

  test "should accept invitation and show choice between sign in and create account" do
    get accept_invitation_url(@invitation.token)
    assert_response :success
    assert_select "a[href=?]", new_registration_path(invitation: @invitation.token), text: /Create new account/i
    assert_select "a[href=?]", new_session_path(invitation: @invitation.token), text: /already have an account/i
  end

  test "should not accept invalid invitation token" do
    get accept_invitation_url("invalid-token")
    assert_response :not_found
  end

  test "admin can remove pending invitation" do
    assert_difference("Invitation.count", -1) do
      delete invitation_url(@invitation)
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("invitations.destroy.success"), flash[:notice]
  end

  test "non-admin cannot remove invitations" do
    sign_in users(:family_member)

    assert_no_difference("Invitation.count") do
      delete invitation_url(@invitation)
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("invitations.destroy.not_authorized"), flash[:alert]
  end

  test "should handle invalid invitation removal" do
    delete invitation_url(id: "invalid-id")
    assert_response :not_found
  end
end
