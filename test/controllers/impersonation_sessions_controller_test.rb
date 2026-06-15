require "test_helper"

class ImpersonationSessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    workspace_family = Family.create!(name: "Risingstone ventures pvt ltd")

    @bootstrap_super_admin = User.create!(
      family: families(:empty),
      first_name: "F0-SU-1",
      email: "adminf0@bookeepz.net",
      password: user_password_test,
      password_confirmation: user_password_test,
      role: :super_admin,
      onboarded_at: Time.current
    )

    @bootstrap_family_admin = User.create!(
      family: workspace_family,
      first_name: "RS-VENTURES-ADMIN",
      email: "admin+rsventures@bookeepz.net",
      password: user_password_test,
      password_confirmation: user_password_test,
      role: :admin,
      onboarded_at: Time.current
    )
  end

  test "impersonation session logs all activity for auditing" do
    sign_in impersonator = users(:sure_support_staff)
    impersonated = users(:family_member)

    impersonator_session = impersonation_sessions(:in_progress)

    post join_impersonation_sessions_path, params: { impersonation_session_id: impersonator_session.id }

    assert_difference "impersonator_session.logs.count", 2 do
      get root_path
      get account_path(impersonated.accessible_accounts.first)
    end
  end

  test "super admin can request an impersonation session" do
    sign_in users(:sure_support_staff)

    post impersonation_sessions_path, params: { impersonation_session: { impersonated_id: users(:family_member).id } }

    assert_equal "Request sent to user. Waiting for approval.", flash[:notice]
    assert_redirected_to root_path
  end

  test "super admin can join and leave an in progress impersonation session" do
    sign_in super_admin = users(:sure_support_staff)

    impersonator_session = impersonation_sessions(:in_progress)

    super_admin_session = super_admin.sessions.order(created_at: :desc).first

    assert_nil super_admin_session.active_impersonator_session

    # Joining the session
    post join_impersonation_sessions_path, params: { impersonation_session_id: impersonator_session.id }
    assert_equal impersonator_session, super_admin_session.reload.active_impersonator_session
    assert_equal "Joined session", flash[:notice]
    assert_redirected_to root_path

    follow_redirect!

    # Leaving the session
    delete leave_impersonation_sessions_path
    assert_nil super_admin_session.reload.active_impersonator_session
    assert_equal "Left session", flash[:notice]
    assert_redirected_to root_path

    # Impersonation session still in progress because nobody has ended it yet
    assert_equal "in_progress", impersonator_session.reload.status
  end

  test "super admin can complete an impersonation session" do
    sign_in super_admin = users(:sure_support_staff)

    impersonator_session = impersonation_sessions(:in_progress)

    put complete_impersonation_session_path(impersonator_session)

    assert_equal "Session completed", flash[:notice]
    assert_nil super_admin.sessions.order(created_at: :desc).first.active_impersonator_session
    assert_equal "complete", impersonator_session.reload.status
    assert_redirected_to root_path
  end

  test "regular user can complete an impersonation session" do
    sign_in regular_user = users(:family_member)

    impersonator_session = impersonation_sessions(:in_progress)

    put complete_impersonation_session_path(impersonator_session)

    assert_equal "Session completed", flash[:notice]
    assert_equal "complete", impersonator_session.reload.status
    assert_redirected_to root_path
  end

  test "super admin cannot accept an impersonation session" do
    sign_in super_admin = users(:sure_support_staff)

    impersonator_session = impersonation_sessions(:in_progress)

    put approve_impersonation_session_path(impersonator_session)

    assert_response :not_found
  end

  test "regular user can accept an impersonation session" do
    sign_in regular_user = users(:family_member)

    impersonator_session = impersonation_sessions(:in_progress)

    put approve_impersonation_session_path(impersonator_session)

    assert_equal "Request approved", flash[:notice]
    assert_equal "in_progress", impersonator_session.reload.status
    assert_redirected_to root_path
  end

  test "regular user can reject an impersonation session" do
    sign_in regular_user = users(:family_member)

    impersonator_session = impersonation_sessions(:in_progress)

    put reject_impersonation_session_path(impersonator_session)

    assert_equal "Request rejected", flash[:notice]
    assert_equal "rejected", impersonator_session.reload.status
    assert_redirected_to root_path
  end

  test "bootstrap super admin auto-activates bootstrap family admin impersonation" do
    sign_in @bootstrap_super_admin

    current_session = @bootstrap_super_admin.sessions.order(created_at: :desc).first

    post impersonation_sessions_path, params: { impersonation_session: { impersonated_id: @bootstrap_family_admin.id } }

    session_record = ImpersonationSession.order(created_at: :desc).first
    assert_equal "in_progress", session_record.status
    assert_equal session_record, current_session.reload.active_impersonator_session
    assert_redirected_to root_path
  end

  test "bootstrap super admin waits for approval when workspace admin mapping drifts" do
    @bootstrap_family_admin.update!(role: :member)
    sign_in @bootstrap_super_admin

    current_session = @bootstrap_super_admin.sessions.order(created_at: :desc).first

    post impersonation_sessions_path, params: { impersonation_session: { impersonated_id: @bootstrap_family_admin.id } }

    session_record = ImpersonationSession.order(created_at: :desc).first
    assert_equal "pending", session_record.status
    assert_nil current_session.reload.active_impersonator_session
    assert_redirected_to root_path
  end
end
