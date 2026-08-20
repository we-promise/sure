require "test_helper"

# SnapTrade user registration, which the device flow needs before any data call.
class SnaptradeItemRegistrationTest < ActiveSupport::TestCase
  setup do
    @item = snaptrade_items(:configured_item)
  end

  test "ensure_user_registered! is a no-op when the stored user still exists" do
    Provider::Snaptrade.any_instance.expects(:list_connections).returns([])
    Provider::Snaptrade.any_instance.expects(:register_user).never

    assert @item.ensure_user_registered!
    assert_equal "user_123", @item.reload.snaptrade_user_id
  end

  test "ensure_user_registered! registers and stores a user when there is none" do
    @item.update!(snaptrade_user_id: nil, snaptrade_user_secret: nil)
    Provider::Snaptrade.any_instance.expects(:register_user)
      .returns({ user_id: "family_x_1", user_secret: "s3cret" })

    assert @item.ensure_user_registered!

    @item.reload
    assert_equal "family_x_1", @item.snaptrade_user_id
    assert_equal "s3cret", @item.snaptrade_user_secret
  end

  test "ensure_user_registered! re-registers when SnapTrade says the user is gone" do
    Provider::Snaptrade.any_instance.expects(:list_connections)
      .raises(Provider::Snaptrade::AuthenticationError.new("no such user"))
    Provider::Snaptrade.any_instance.expects(:register_user)
      .returns({ user_id: "family_x_2", user_secret: "fresh" })

    assert @item.ensure_user_registered!
    assert_equal "family_x_2", @item.reload.snaptrade_user_id
  end

  # user_secret is returned exactly once and cannot be recovered, so a
  # transient failure must never be taken as proof the user is gone.
  test "ensure_user_registered! keeps credentials when verification fails transiently" do
    Provider::Snaptrade.any_instance.expects(:list_connections)
      .raises(Provider::Snaptrade::ApiError.new("Rate limit exceeded", status_code: 429))
    Provider::Snaptrade.any_instance.expects(:register_user).never

    assert_raises(Provider::Snaptrade::ApiError) { @item.ensure_user_registered! }

    @item.reload
    assert_equal "user_123", @item.snaptrade_user_id
    assert_equal "secret_abc", @item.snaptrade_user_secret
  end

  test "verify_user_exists? distinguishes a missing user from an unknown outcome" do
    Provider::Snaptrade.any_instance.expects(:list_connections).returns([])
    assert_equal :ok, @item.verify_user_exists?

    Provider::Snaptrade.any_instance.expects(:list_connections)
      .raises(Provider::Snaptrade::AuthenticationError.new("gone"))
    assert_equal :missing, @item.verify_user_exists?

    Provider::Snaptrade.any_instance.expects(:list_connections)
      .raises(Provider::Snaptrade::ApiError.new("boom", status_code: 500))
    assert_equal :unknown, @item.verify_user_exists?
  end

  test "orphaned_users lists this family's earlier registrations only" do
    family_id = @item.family_id
    Provider::Snaptrade.any_instance.expects(:list_users).returns(
      [ "user_123", "family_#{family_id}_111", "family_someone_else_222" ]
    )

    assert_equal [ "family_#{family_id}_111" ], @item.orphaned_users
  end

  test "delete_orphaned_user refuses ids outside this family" do
    Provider::Snaptrade.any_instance.expects(:delete_user).never

    assert_not @item.delete_orphaned_user("family_someone_else_222")
    assert_not @item.delete_orphaned_user(@item.snaptrade_user_id)
  end

  test "a deprecated PKCE connection has no SnapTrade user to register" do
    legacy_item = snaptrade_items(:legacy_oauth_item)

    assert_not legacy_item.user_registered?
    assert_empty legacy_item.orphaned_users
    assert_empty legacy_item.list_all_users
  end
end
