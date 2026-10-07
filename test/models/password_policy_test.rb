require "test_helper"

class PasswordPolicyTest < ActiveSupport::TestCase
  test "a password meeting every rule has no unmet requirements" do
    assert_empty PasswordPolicy.unmet_requirements("NewSecure1!")
  end

  test "lists each unmet rule in display order" do
    assert_equal %i[too_short missing_case missing_number missing_special], PasswordPolicy.unmet_requirements("abc")
    assert_equal %i[missing_number missing_special], PasswordPolicy.unmet_requirements("Abcdefgh")
    assert_equal %i[missing_special], PasswordPolicy.unmet_requirements("Abcdefg1")
  end

  test "treats nil like an empty password" do
    assert_equal %i[too_short missing_case missing_number missing_special], PasswordPolicy.unmet_requirements(nil)
  end
end
