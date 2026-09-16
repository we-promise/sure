require "test_helper"
require_relative "../support/account_unlink_test_helper"

# These action tests replace the transactional DELETE-unlink cases from
# AccountsControllerTest. Session-level legacy admission must precede any DB
# transaction, so each example creates and cleans up its own account/sources.
class AccountUnlinkControllerTest < ActionDispatch::IntegrationTest
  include AccountUnlinkTestHelper
  self.use_transactional_tests = false

  setup do
    DebugLogEntry.stubs(:capture)
    @user = users(:family_admin)
    @session_ids = @user.sessions.pluck(:id)
    @session_user_attributes = @user.reload.attributes.slice("sessions_count", "last_login_at")
    sign_in @user
  end

  teardown do
    @user.sessions.where.not(id: @session_ids).delete_all
    @user.update_columns(@session_user_attributes)
  end

  test "unlinks a provider join and preserves the Plaid source" do
    with_unlink_account do |context|
      source = add_unlink_source(context, "plaid")

      delete unlink_account_url(context.account)

      assert_not context.account.reload.linked?
      assert PlaidAccount.exists?(source.id)
      assert_redirected_to accounts_path
      assert_equal "Account unlinked successfully. It is now a manual account.", flash[:notice]
    end
  end

  test "unlinks a direct legacy Plaid foreign key" do
    with_unlink_account do |context|
      source = add_unlink_source(context, "plaid", link: false)
      context.account.update!(plaid_account: source)

      delete unlink_account_url(context.account)

      assert_nil context.account.reload.plaid_account_id
      assert_not context.account.linked?
      assert PlaidAccount.exists?(source.id)
      assert_redirected_to accounts_path
      assert_equal "Account unlinked successfully. It is now a manual account.", flash[:notice]
    end
  end

  test "manual accounts retain the existing not linked response" do
    with_unlink_account do |context|
      delete unlink_account_url(context.account)

      assert_redirected_to account_url(context.account)
      assert_equal "Account is not linked to a provider", flash[:alert]
    end
  end

  test "a linked account may be scheduled for deletion only after unlinking" do
    with_unlink_account do |context|
      add_unlink_source(context, "plaid")
      delete account_url(context.account)
      assert_redirected_to account_url(context.account)
      assert_equal "Cannot delete a linked account. Please unlink it first.", flash[:alert]

      delete unlink_account_url(context.account)
      delete account_url(context.account)

      assert_redirected_to accounts_path
      assert_enqueued_with job: DestroyJob
      assert_equal "Depository account scheduled for deletion", flash[:notice]
    end
  end

  test "unlink preserves SnapTrade and does not enqueue remote connection cleanup" do
    with_unlink_account do |context|
      source = add_unlink_source(context, "snaptrade")
      link = context.account.account_providers.sole
      holding = unlink_holding(context.account, link)

      assert_no_enqueued_jobs(only: SnaptradeConnectionCleanupJob) { delete unlink_account_url(context.account) }

      assert_redirected_to accounts_path
      assert_not context.account.reload.linked?
      assert SnaptradeAccount.exists?(source.id)
      assert_not AccountProvider.exists?(link.id)
      assert_nil holding.reload.account_provider_id
      assert_equal BigDecimal("200"), holding.amount
    end
  end

  test "cleanup failure uses the existing generic response and leaves the account linked" do
    with_unlink_account do |context|
      source = add_unlink_source(context, "simplefin")
      context.account.update!(simplefin_account: source)
      SimplefinAccount.any_instance.expects(:destroy!).raises(IOError, "private upstream error")

      delete unlink_account_url(context.account)

      assert_redirected_to account_url(context.account)
      assert context.account.reload.linked?
      assert_includes flash[:alert], I18n.t("accounts.unlink.generic_error")
      refute_includes flash[:alert], "private upstream error"
    end
  end

  test "the command's current permission refusal preserves the authorization response" do
    with_unlink_account do |context|
      add_unlink_source(context, "plaid")
      Account::Unlink.any_instance.expects(:call).raises(Account::Unlink::NotAuthorized)

      delete unlink_account_url(context.account)

      assert_redirected_to account_url(context.account)
      assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
      assert context.account.reload.linked?
    end
  end
end
