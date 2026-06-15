require "test_helper"

class ImpersonationSessionTest < ActiveSupport::TestCase
  setup do
    @bootstrap_super_admin = User.create!(
      family: families(:empty),
      first_name: "F0-SU-1",
      email: "adminf0@bookeepz.net",
      password: "Password1!",
      password_confirmation: "Password1!",
      role: :super_admin,
      onboarded_at: Time.current
    )

    @bootstrap_family_admin = User.create!(
      family: families(:dylan_family),
      first_name: "RS-VENTURES-ADMIN",
      email: "admin+rsventures@bookeepz.net",
      password: "Password1!",
      password_confirmation: "Password1!",
      role: :admin,
      onboarded_at: Time.current
    )
  end

  test "only super admin can impersonate" do
    regular_user = users(:family_member)

    assert_not regular_user.super_admin?

    assert_raises(ActiveRecord::RecordInvalid) do
      ImpersonationSession.create!(
        impersonator: regular_user,
        impersonated: users(:sure_support_staff)
      )
    end
  end

  test "super admin cannot be impersonated" do
    super_admin = users(:sure_support_staff)

    assert super_admin.super_admin?

    assert_raises(ActiveRecord::RecordInvalid) do
      ImpersonationSession.create!(
        impersonator: users(:family_member),
        impersonated: super_admin
      )
    end
  end

  test "impersonation session must have different impersonator and impersonated" do
    super_admin = users(:sure_support_staff)

    assert_raises(ActiveRecord::RecordInvalid) do
      ImpersonationSession.create!(
        impersonator: super_admin,
        impersonated: super_admin
      )
    end
  end

  test "bootstrap super admin can auto approve bootstrap family admin impersonation" do
    session = ImpersonationSession.create!(
      impersonator: @bootstrap_super_admin,
      impersonated: @bootstrap_family_admin
    )

    assert_equal "in_progress", session.status
  end

  test "other super admins do not auto approve bootstrap family admin impersonation" do
    session = ImpersonationSession.create!(
      impersonator: users(:sure_support_staff),
      impersonated: @bootstrap_family_admin
    )

    assert_equal "pending", session.status
  end
end
