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
    original_family_id = existing_user.family_id
    assert original_family_id != @admin.family_id

    assert_difference("Invitation.count") do
      assert_difference("Membership.count") do
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

    # User keeps their original family (not overwritten)
    existing_user.reload
    assert_equal original_family_id, existing_user.family_id

    # But a membership was created for the admin's family
    membership = existing_user.membership_for(@admin.family)
    assert_not_nil membership
    assert_equal "member", membership.role

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("invitations.create.existing_user_added"), flash[:notice]
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

  test "inviting an existing user as guest creates guest membership" do
    existing_user = users(:empty)

    assert_difference("Invitation.count") do
      assert_difference("Membership.count") do
        post invitations_url, params: {
          invitation: {
            email: existing_user.email,
            role: "guest"
          }
        }
      end
    end

    membership = existing_user.membership_for(@admin.family)
    assert_not_nil membership
    assert_equal "guest", membership.role
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
