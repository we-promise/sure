require "test_helper"

class Rule::ActionExecutor::SendEmailNotificationTest < ActiveSupport::TestCase
  include EntriesTestHelper, ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @rule = rules(:one)
    @account = @family.accounts.create!(name: "Notify test", balance: 1000, currency: "USD", accountable: Depository.new)
    @txn1 = create_transaction(date: Date.current, account: @account, amount: 100, name: "Coffee").transaction
    @scope = @account.transactions
  end

  def action
    Rule::Action.new(rule: @rule, action_type: "send_email_notification")
  end

  test "enqueues one digest job for new matches, records deliveries, returns integer count" do
    result = nil

    assert_difference -> { NotificationDelivery.where(rule: @rule).count }, 1 do
      assert_enqueued_with(job: RuleEmailNotificationJob) do
        result = action.apply(@scope)
      end
    end

    assert_equal 1, result
    assert_includes NotificationDelivery.where(rule: @rule).pluck(:transaction_id), @txn1.id
  end

  test "dedup suppresses repeat sends across runs" do
    action.apply(@scope)

    result = nil
    assert_no_enqueued_jobs only: RuleEmailNotificationJob do
      result = action.apply(@scope)
    end

    assert_equal 0, result
    assert_equal 1, NotificationDelivery.where(rule: @rule).count
  end

  test "only newly appearing transactions trigger a job" do
    action.apply(@scope) # baseline: txn1 recorded + enqueued

    txn2 = create_transaction(date: Date.current, account: @account, amount: 50, name: "Lunch").transaction

    result = nil
    # Only txn2 (the newly appearing match) may be enqueued — never the already
    # notified txn1. Asserting the args, not just the job class, locks that down.
    assert_enqueued_with(job: RuleEmailNotificationJob, args: [ @rule.id, [ txn2.id ] ]) do
      result = action.apply(@scope)
    end

    assert_equal 1, result
    recorded = NotificationDelivery.where(rule: @rule).pluck(:transaction_id)
    assert_includes recorded, txn2.id
    assert_equal 2, recorded.size
  end

  test "pre-seed watermark records existing matches without sending so history never emails" do
    # after_create_commit does not fire under transactional tests (the wrapping
    # transaction never commits), so invoke the seeding path directly to verify
    # the watermark behavior the callback performs in production.
    rule = @family.rules.create!(
      resource_type: "transaction",
      actions_attributes: [ { action_type: "send_email_notification" } ]
    )
    seed_action = rule.actions.first

    assert_no_enqueued_jobs only: RuleEmailNotificationJob do
      seed_action.send(:seed_notification_baseline)
    end

    # Pre-existing @txn1 is now watermarked, so a subsequent run sends nothing.
    result = nil
    assert_no_enqueued_jobs only: RuleEmailNotificationJob do
      result = Rule::Action.new(rule: rule, action_type: "send_email_notification").apply(@scope)
    end

    assert_equal 0, result
    assert_includes NotificationDelivery.where(rule: rule).pluck(:transaction_id), @txn1.id
  end
end
