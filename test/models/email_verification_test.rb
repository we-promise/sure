require "test_helper"

class EmailVerificationTest < ActiveSupport::TestCase
  test "enforced? mirrors the require_email_confirmation setting" do
    Setting.require_email_confirmation = true
    assert EmailVerification.enforced?

    Setting.require_email_confirmation = false
    assert_not EmailVerification.enforced?
  end
end
