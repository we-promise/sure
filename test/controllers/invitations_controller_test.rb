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

  test "inviting an email that already belongs to an account answers like any invitation and moves no one" do
    existing_user = users(:empty)
    original_family_id = existing_user.family_id

    assert_difference("Invitation.count", 1) do
      post invitations_url, params: { invitation: { email: existing_user.email, role: "member" } }
    end

    existing_user.reload
    assert_equal original_family_id, existing_user.family_id
    assert_equal "admin", existing_user.role
    assert_redirected_to settings_profile_path
    assert_equal I18n.t("invitations.create.success"), flash[:notice]
  end

  test "admin cannot invite their own email and keeps the admin role" do
    assert_no_difference("Invitation.count") do
      post invitations_url, params: { invitation: { email: " #{@admin.email.upcase} ", role: "member" } }
    end

    assert_equal "admin", @admin.reload.role
    assert_equal I18n.t("invitations.create.own_email"), flash[:alert]
  end

  test "inviting a current household member does not change their role" do
    member = users(:family_member)

    post invitations_url, params: { invitation: { email: member.email, role: "admin" } }

    assert_equal "member", member.reload.role
    assert_equal I18n.t("invitations.create.success"), flash[:notice]
  end

  test "super admin cannot invite their own email and keeps the super admin role" do
    sign_in staff = users(:sure_support_staff)

    assert_no_difference("Invitation.count") do
      post invitations_url, params: { invitation: { email: staff.email, role: "member" } }
    end

    assert_redirected_to settings_profile_path
    assert_equal "super_admin", staff.reload.role
    assert_equal I18n.t("invitations.create.own_email"), flash[:alert]
  end

  test "should add an existing user whose email row is still legacy plaintext" do
    existing_user = users(:empty)
    email = store_legacy_plaintext_email(existing_user)

    post invitations_url, params: { invitation: { email: email, role: "member" } }

    assert_equal @admin.family_id, existing_user.reload.family_id
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

  test "re-inviting an email whose prior invitation expired succeeds instead of 500ing" do
    email = "expired-reinvite-ctrl@example.com"
    expired = @admin.family.invitations.create!(email: email, role: "member", inviter: @admin)
    expired.update_column(:expires_at, 1.day.ago)

    post invitations_url, params: {
      invitation: {
        email: email,
        role: "member"
      }
    }

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("invitations.create.success"), flash[:notice]
    assert_not Invitation.exists?(expired.id), "stale expired invitation should be replaced"

    new_invitation = @admin.family.invitations.find_by(email: email)
    assert new_invitation.present?
    assert new_invitation.pending?
  end

  test "raced unique-index violation on save is handled as a failure, not a 500" do
    # Simulate a concurrent double-submit that slips past the pending-invite
    # validation and hits the partial unique index at INSERT time.
    Invitation.any_instance.stubs(:save).raises(ActiveRecord::RecordNotUnique)

    assert_no_difference("Invitation.count") do
      post invitations_url, params: {
        invitation: {
          email: "raced@example.com",
          role: "member"
        }
      }
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("invitations.create.failure"), flash[:alert]
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

  test "should get bulk_new" do
    get bulk_new_invitations_url
    assert_response :success
    assert_select "option[value=?]", "member"
    assert_select "option[value=?]", "admin", count: 0
  end

  test "bulk_create rejects the admin role" do
    assert_no_difference("Invitation.count") do
      post bulk_create_invitations_url, params: {
        bulk_invitation: {
          emails: "escalate@example.com",
          role: "admin"
        }
      }
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("invitations.bulk_create.invalid_role"), flash[:alert]
  end

  test "bulk_create handles a non-hash bulk_invitation param without 500ing" do
    assert_no_difference("Invitation.count") do
      post bulk_create_invitations_url, params: { bulk_invitation: "member" }
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("invitations.bulk_create.invalid_role"), flash[:alert]
  end

  test "non-admin cannot get bulk_new" do
    sign_in users(:family_member)
    get bulk_new_invitations_url
    assert_redirected_to settings_profile_path
    assert_equal I18n.t("invitations.create.failure"), flash[:alert]
  end

  test "bulk_create sends invitations to multiple new emails" do
    Rails.application.config.stubs(:app_mode).returns("managed".inquiry)

    assert_difference("Invitation.count", 2) do
      assert_enqueued_jobs 2, only: ActionMailer::MailDeliveryJob do
        post bulk_create_invitations_url, params: {
          bulk_invitation: {
            emails: "one@example.com, two@example.com",
            role: "member"
          }
        }
      end
    end

    assert_response :success
    assert @admin.family.invitations.pending.where(email: "one@example.com").exists?
    assert @admin.family.invitations.pending.where(email: "two@example.com").exists?
  end

  test "bulk_create de-duplicates emails within the batch" do
    Rails.application.config.stubs(:app_mode).returns("managed".inquiry)

    assert_difference("Invitation.count", 1) do
      post bulk_create_invitations_url, params: {
        bulk_invitation: {
          emails: "dup@example.com\ndup@example.com\n DUP@example.com ",
          role: "member"
        }
      }
    end

    assert_response :success
    assert_equal 1, @admin.family.invitations.where(email: "dup@example.com").count
  end

  test "bulk_create invites an existing user's email without moving them and skips blanks" do
    Rails.application.config.stubs(:app_mode).returns("managed".inquiry)
    existing_user = users(:empty)
    original_family_id = existing_user.family_id
    assert original_family_id != @admin.family_id

    assert_difference("Invitation.count", 2) do
      post bulk_create_invitations_url, params: {
        bulk_invitation: {
          emails: "#{existing_user.email}, , new-person@example.com",
          role: "member"
        }
      }
    end

    assert_response :success
    # An invitation never moves an existing account; the blank entry is dropped.
    assert_equal original_family_id, existing_user.reload.family_id
    assert @admin.family.invitations.pending.where(email: existing_user.email).exists?
    assert @admin.family.invitations.pending.where(email: "new-person@example.com").exists?
  end

  test "bulk_create processes a batch of exactly the cap" do
    Rails.application.config.stubs(:app_mode).returns("managed".inquiry)
    emails = Array.new(BulkInvitation::MAX_BULK_INVITES) { |i| "exact#{i}@example.com" }.join("\n")

    assert_difference("Invitation.count", BulkInvitation::MAX_BULK_INVITES) do
      post bulk_create_invitations_url, params: {
        bulk_invitation: { emails: emails, role: "member" }
      }
    end

    assert_response :success
  end

  test "bulk_create rejects an empty batch" do
    assert_no_difference("Invitation.count") do
      post bulk_create_invitations_url, params: {
        bulk_invitation: { emails: "   \n  ", role: "member" }
      }
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("invitations.bulk_create.no_emails"), flash[:alert]
  end

  test "bulk_create rejects batches over the cap before creating any invitations" do
    emails = Array.new(BulkInvitation::MAX_BULK_INVITES + 1) { |i| "cap#{i}@example.com" }.join("\n")

    assert_no_difference("Invitation.count") do
      post bulk_create_invitations_url, params: {
        bulk_invitation: { emails: emails, role: "member" }
      }
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("invitations.bulk_create.too_many", max: BulkInvitation::MAX_BULK_INVITES), flash[:alert]
  end

  test "non-admin cannot bulk_create invitations" do
    sign_in users(:family_member)

    assert_no_difference("Invitation.count") do
      post bulk_create_invitations_url, params: {
        bulk_invitation: {
          emails: "new@example.com",
          role: "admin"
        }
      }
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("invitations.create.failure"), flash[:alert]
  end

  test "accepting an invitation offers account creation only" do
    get accept_invitation_url(@invitation.token)
    assert_response :success
    assert_select "a[href=?]", new_registration_path(invitation: @invitation.token), text: /Create new account/i
    assert_select "a[href=?]", new_session_path(invitation: @invitation.token), count: 0
    assert_select "p", text: I18n.t("invitations.accept_choice.existing_account_hint")
  end

  test "accept page looks the same when the invited email already has an account" do
    # Dialogs get random element ids on every render.
    page = -> { response.body.gsub(/dialog-title-\h+/, "") }
    get accept_invitation_url(@invitation.token)
    new_email_page = page.call

    @invitation.update_columns(email: users(:family_member).email)
    get accept_invitation_url(@invitation.token)

    assert_response :success
    assert_equal new_email_page, page.call
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
