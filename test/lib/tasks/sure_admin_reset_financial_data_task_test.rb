require "test_helper"
require "rake"

class SureAdminResetFinancialDataTaskTest < ActiveSupport::TestCase
  TASK_NAME = "sure:admin:reset_financial_data"

  setup do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |task| task.name == TASK_NAME }
    @task = Rake::Task[TASK_NAME]
    @user = users(:family_admin)
  end

  teardown do
    %w[USER_EMAIL DRY_RUN CONFIRM_RESET_FINANCIAL_DATA].each { |key| ENV.delete(key) }
    @task.reenable
  end

  test "refuses to run without a user email" do
    error = assert_raises(SystemExit) { capture_io { @task.invoke } }

    assert_equal 1, error.status
  end

  test "dry run prints counts and deletes nothing" do
    ENV["USER_EMAIL"] = @user.email
    before_accounts = @user.family.accounts.count

    stdout, = capture_io { @task.invoke }

    assert_includes stdout, "Resolved user: #{@user.email}"
    assert_includes stdout, "Mode: dry-run"
    assert_includes stdout, "Before counts:"
    assert_includes stdout, "Deleted counts:"
    assert_includes stdout, "After counts:"
    assert_equal before_accounts, @user.family.accounts.reload.count
    assert User.exists?(@user.id)
  end

  test "destructive run requires explicit confirmation" do
    ENV["USER_EMAIL"] = @user.email
    ENV["DRY_RUN"] = "false"

    error = assert_raises(SystemExit) { capture_io { @task.invoke } }

    assert_equal 1, error.status
    assert_operator @user.family.accounts.reload.count, :>, 0
  end

  test "destructive run clears selected family and preserves user" do
    ENV["USER_EMAIL"] = @user.email
    ENV["CONFIRM_RESET_FINANCIAL_DATA"] = "yes"

    stdout, = capture_io { @task.invoke }

    assert_includes stdout, "Mode: destructive"
    assert_includes stdout, "Financial data reset complete."
    assert_equal 0, Family::FinancialDataReset.new(user: @user).call.before_counts.values.sum
    assert User.exists?(@user.id)
  end
end
