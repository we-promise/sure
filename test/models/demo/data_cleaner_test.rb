require "test_helper"

class Demo::DataCleanerTest < ActiveSupport::TestCase
  setup do
    # Fixture families hold Plaid items, and destroying one asks Plaid to
    # remove it. That call is not what these tests are about.
    Provider::Registry.stubs(:plaid_provider_for_region).returns(nil)
  end

  # The generator gives its demo family a fake Stripe subscription, and a
  # family cancels its subscription at Stripe before it goes. The cancel always
  # failed, so `rake demo_data:default SKIP_CLEAR=0` could never remove the
  # demo family it had created itself.
  test "clears a family with a Stripe subscription without calling Stripe" do
    family = Family.create!(name: "Demo Family")
    family.start_subscription!("sub_demo_123")
    Provider::Registry.expects(:get_provider).with(:stripe).never

    clear!

    assert_equal 0, Family.count
    assert_equal 0, Subscription.count
  end

  test "clears the last active super admin" do
    admin = users(:family_admin)
    User.where(role: "super_admin").where.not(id: admin.id).update_all(role: "admin")
    admin.update_columns(role: "super_admin", active: true)

    clear!

    assert_equal 0, User.count
  end

  # Neither row has an association that removes it, and each one's foreign key
  # stopped the cascade at the family or user it points to.
  test "clears families that unlinked a merchant or were impersonated" do
    FamilyMerchantAssociation.create!(family: families(:dylan_family), merchant: merchants(:netflix),
                                      unlinked_at: 1.day.ago)
    impersonation_sessions(:in_progress).logs.create!(controller: "pages", action: "dashboard",
                                                      method: "GET", path: "/")

    clear!

    assert_equal 0, Family.count
    assert_equal 0, ImpersonationSessionLog.count
  end

  # Family.destroy_all skipped a family whose destroy aborted without a word,
  # then wiped the settings, invite codes and exchange rates anyway.
  test "a family that cannot be destroyed stops the reset before anything else goes" do
    Setting.exchange_rate_provider = "yahoo_finance"
    families = Family.count
    exchange_rates = ExchangeRate.count
    assert exchange_rates.positive?, "the fixtures carry exchange rates for this check"

    Family.any_instance.stubs(:destroy!).raises(ActiveRecord::RecordNotDestroyed.new("Failed to destroy Family"))

    assert_raises(ActiveRecord::RecordNotDestroyed) { clear! }

    assert_equal families, Family.count
    assert_equal exchange_rates, ExchangeRate.count
    assert_equal "yahoo_finance", Setting.exchange_rate_provider
  end

  # The guards are disarmed before any family goes. A reset that fails after
  # that must not leave subscriptions cancelled and the super admin demoted.
  test "a failed reset rolls back what it already did" do
    subscription = subscriptions(:active)
    super_admin = User.find_by!(role: "super_admin")
    Family.any_instance.stubs(:destroy!).raises(ActiveRecord::RecordNotDestroyed.new("Failed to destroy Family"))

    assert_raises(ActiveRecord::RecordNotDestroyed) { clear! }

    assert_equal "active", subscription.reload.status
    assert_equal "super_admin", super_admin.reload.role
  end

  test "a failed destroy names the guard that aborted it" do
    user = users(:family_admin)
    user.errors.add(:base, "cannot remove the last super admin")
    Family.any_instance.stubs(:destroy!).raises(ActiveRecord::RecordNotDestroyed.new("Failed to destroy User", user))

    error = assert_raises(ActiveRecord::RecordNotDestroyed) { clear! }

    assert_includes error.message, "cannot remove the last super admin"
    assert_equal user, error.record
  end

  private
    def clear!
      capture_io { Demo::DataCleaner.new.destroy_everything! }
    end
end
