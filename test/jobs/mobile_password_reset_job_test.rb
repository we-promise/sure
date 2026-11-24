require "test_helper"

class MobilePasswordResetJobTest < ActiveJob::TestCase
  test "emails a known password user" do
    assert_enqueued_jobs 1, only: ActionMailer::MailDeliveryJob do
      MobilePasswordResetJob.perform_now(users(:family_admin).email)
    end
  end

  test "sends nothing for an unknown email" do
    assert_no_enqueued_jobs only: ActionMailer::MailDeliveryJob do
      MobilePasswordResetJob.perform_now("nobody@example.com")
    end
  end

  test "sends nothing to an SSO-only user" do
    assert_no_enqueued_jobs only: ActionMailer::MailDeliveryJob do
      MobilePasswordResetJob.perform_now(users(:sso_only).email)
    end
  end

  test "sends nothing when password features are disabled" do
    AuthConfig.stubs(:password_features_enabled?).returns(false)

    assert_no_enqueued_jobs only: ActionMailer::MailDeliveryJob do
      MobilePasswordResetJob.perform_now(users(:family_admin).email)
    end
  end
end
