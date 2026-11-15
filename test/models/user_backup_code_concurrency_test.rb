require "test_helper"
require "concurrent"

# A backup code is single use. Two requests redeeming the same code at once,
# each on its own connection and its own stale User instance, must not both
# succeed: consume_backup_code! takes a row lock and re-reads the codes, so the
# second one sees the code already gone.
#
# Real threads on real connections, so this needs real commits.
class UserBackupCodeConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @user = users(:family_member)
    @original = @user.attributes.slice("otp_secret", "otp_required", "otp_backup_codes")
    @user.setup_mfa!
    @codes = @user.enable_mfa!
  end

  teardown do
    User.where(id: @user.id).update_all(@original)
  end

  test "two connections redeeming the same backup code consume it exactly once" do
    code = @codes.first
    latch = Concurrent::CountDownLatch.new(2)

    results = 2.times.map do
      instance = User.find(@user.id)
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          latch.count_down
          assert latch.wait(5), "both workers must reach the redemption checkpoint"
          instance.send(:consume_backup_code!, code)
        end
      end
    end.map(&:value)

    assert_equal 1, results.count(true), "exactly one racing connection may redeem the code"
    assert_equal @codes.size - 1, @user.reload.otp_backup_codes.size
  end
end
