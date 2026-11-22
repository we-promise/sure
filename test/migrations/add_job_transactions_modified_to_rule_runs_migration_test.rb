# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261121093556_add_job_transactions_modified_to_rule_runs")

# Up copies transactions_modified to job_transactions_modified on runs it finds
# still waiting on their AI jobs, whose transactions_modified holds only what
# those jobs have reported. The schema changes roll back with the test's
# transaction.
class AddJobTransactionsModifiedToRuleRunsMigrationTest < ActiveSupport::TestCase
  teardown { RuleRun.reset_column_information }

  test "up backfills the AI changes of runs whose jobs are still pending" do
    rule = families(:empty).rules.create!(
      name: "AI", resource_type: "transaction",
      actions: [ Rule::Action.new(action_type: "auto_categorize") ]
    )
    pending = create_run(rule, status: "pending", pending_jobs_count: 1, transactions_modified: 3)
    failed = create_run(rule, status: "failed", pending_jobs_count: 1, transactions_modified: 2)
    done = create_run(rule, status: "success", pending_jobs_count: 0, transactions_modified: 5)

    migrate(:down)
    migrate(:up)

    assert_equal 3, pending.reload.job_transactions_modified
    assert_equal 2, failed.reload.job_transactions_modified
    assert_equal 0, done.reload.job_transactions_modified
  end

  test "down then up restores the column and its default" do
    before = column_shape

    migrate(:down)
    assert_nil column_shape
    migrate(:up)

    assert_equal before, column_shape
    assert_equal({ type: "integer", default: "0", null: false }, before)
  end

  private
    def migrate(direction)
      ActiveRecord::Migration.suppress_messages { AddJobTransactionsModifiedToRuleRuns.new.migrate(direction) }
      RuleRun.reset_column_information
    end

    def column_shape
      column = ActiveRecord::Base.connection.columns(:rule_runs).find { |c| c.name == "job_transactions_modified" }
      column && { type: column.sql_type, default: column.default, null: column.null }
    end

    def create_run(rule, status:, pending_jobs_count:, transactions_modified:)
      rule.rule_runs.create!(
        rule_name: rule.name, execution_type: "scheduled", status: status,
        transactions_queued: 10, transactions_processed: 10,
        transactions_modified: transactions_modified,
        pending_jobs_count: pending_jobs_count, executed_at: Time.current
      )
    end
end
