require "test_helper"

class ClearStaleContributionCategoriesTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("data_migration:clear_stale_contribution_categories")
    Rake::Task["data_migration:clear_stale_contribution_categories"].reenable
    @family = families(:dylan_family)
    @stale = stale_leg(accounts(:depository))
  end

  teardown do
    ENV.delete("DRY_RUN")
    ENV.delete("BATCH_SIZE")
    ENV.delete("FAMILY_ID")
  end

  test "a dry run counts the stale legs and clears nothing" do
    ENV["DRY_RUN"] = "true"

    out, = capture_io { Rake::Task["data_migration:clear_stale_contribution_categories"].invoke }

    assert_match "Dry run: 1 plain transfer legs would lose", out
    assert_not_nil @stale.reload.category_id
  end

  test "clears in batches of BATCH_SIZE, one call per batch" do
    second = stale_leg(accounts(:depository))
    ENV["BATCH_SIZE"] = "1"
    batches = []
    Transaction.stubs(:drop_stale_contribution_categories!).with { |scope| batches << scope.pluck(:id) }.returns(1)

    capture_io { Rake::Task["data_migration:clear_stale_contribution_categories"].invoke }

    assert_equal [ [ @stale.id ], [ second.id ] ].sort, batches.sort
  end

  test "clears every stale leg across several batches" do
    second = stale_leg(accounts(:depository))
    ENV["BATCH_SIZE"] = "1"

    out, = capture_io { Rake::Task["data_migration:clear_stale_contribution_categories"].invoke }

    assert_match "2 plain transfer legs lost", out
    assert_nil @stale.reload.category_id
    assert_nil second.reload.category_id
  end

  test "FAMILY_ID limits the cleanup to that family" do
    other_family = families(:empty)
    other_account = other_family.accounts.create!(name: "Other checking", balance: 0, currency: "USD", accountable: Depository.new)
    other = stale_leg(other_account)
    ENV["FAMILY_ID"] = @family.id

    capture_io { Rake::Task["data_migration:clear_stale_contribution_categories"].invoke }

    assert_nil @stale.reload.category_id
    assert_not_nil other.reload.category_id
  end

  test "clears the stale legs and reports how many it cleared" do
    out, = capture_io { Rake::Task["data_migration:clear_stale_contribution_categories"].invoke }

    assert_match "1 plain transfer legs lost", out
    assert_nil @stale.reload.category_id
  end

  private
    def stale_leg(account)
      account.entries.create!(
        name: "To broker", amount: 100, date: Date.current, currency: "USD",
        entryable: Transaction.new(kind: "investment_contribution", category: account.family.investment_contributions_category)
      ).transaction.tap { |transaction| transaction.update_columns(kind: "funds_movement") }
    end
end
