require "test_helper"

class InviteCodeTest < ActiveSupport::TestCase
  test "claim! increments successful signups without deleting the invite token" do
    code = InviteCode.generate!
    invite_code = InviteCode.find_by_token(code)

    assert_no_difference "InviteCode.count" do
      InviteCode.claim! code
    end

    assert_equal 1, invite_code.reload.successful_signups_count
  end

  test "claim! returns true if valid" do
    assert InviteCode.claim!(InviteCode.generate!)
  end

  test "claim! is falsy if invalid" do
    assert_not InviteCode.claim!("invalid")
  end

  test "generate! creates a new invite and returns its token" do
    assert_difference "InviteCode.count", +1 do
      assert_equal InviteCode.generate!, InviteCode.last.token
    end
  end

  test "record_signup_attempt! increments attempts without deleting the invite token" do
    code = InviteCode.generate!
    invite_code = InviteCode.find_by_token(code)

    assert_no_difference "InviteCode.count" do
      InviteCode.record_signup_attempt!(code)
    end

    assert_equal 1, invite_code.reload.signup_attempts_count
  end
end
