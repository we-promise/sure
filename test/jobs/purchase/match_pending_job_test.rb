require "test_helper"

class Purchase::MatchPendingJobTest < ActiveJob::TestCase
  include EntriesTestHelper
  include ActionMailer::TestHelper

  setup do
    @ordered_on = Date.current - 5.days
    @purchase = purchases(:allegro_awaiting)
    @purchase.update!(ordered_on: @ordered_on, total: BigDecimal("249.99"), currency: "USD",
                      match_deadline_on: @ordered_on + Purchase::DEADLINE_DAYS)
  end

  test "a payment that arrives later is linked and the user told" do
    entry = payment(date: @ordered_on + 1.day)

    assert_enqueued_email_with PurchaseMailer, :matched, params: { purchase: @purchase } do
      perform
    end

    assert_equal entry.entryable, @purchase.reload.linked_transaction
  end

  test "past the deadline the purchase becomes unmatched with a single email" do
    travel_to @ordered_on + Purchase::DEADLINE_DAYS + 1.day do
      assert_enqueued_email_with PurchaseMailer, :unmatched, params: { purchase: @purchase } do
        perform
      end
      assert_equal "unmatched", @purchase.reload.status
      assert_not_nil @purchase.unmatched_notified_at

      assert_no_enqueued_emails { perform }
    end
  end

  test "an unmatched purchase still matches a statement imported weeks later" do
    @purchase.update!(status: :unmatched, unmatched_notified_at: 1.day.ago)

    travel_to @ordered_on + 40.days do
      payment(date: @ordered_on + 2.days)

      assert_enqueued_email_with PurchaseMailer, :matched, params: { purchase: @purchase } do
        perform
      end
    end

    assert_equal "matched", @purchase.reload.status
  end

  test "a purchase that gets several candidates later asks the user to pick, once" do
    payment(date: @ordered_on)
    payment(date: @ordered_on + 1.day)

    assert_enqueued_email_with PurchaseMailer, :needs_matching, params: { purchase: @purchase } do
      perform
    end
    assert_equal "needs_matching", @purchase.reload.status

    assert_no_enqueued_emails { perform }
  end

  test "a purchase still waiting for a pick at the deadline gets one reminder" do
    payment(date: @ordered_on)
    payment(date: @ordered_on + 1.day)
    @purchase.apply_match!

    travel_to @ordered_on + Purchase::DEADLINE_DAYS + 1.day do
      assert_enqueued_email_with PurchaseMailer, :needs_matching, params: { purchase: @purchase } do
        perform
      end
      assert_equal "needs_matching", @purchase.reload.status
      assert_no_enqueued_emails { perform }
    end
  end

  test "purchases older than the horizon are left alone" do
    @purchase.update!(ordered_on: Date.current - Purchase::MATCH_HORIZON_DAYS - 1.day)
    payment(date: @purchase.ordered_on)

    perform

    assert_equal "awaiting_payment", @purchase.reload.status
  end

  test "a candidate list is refreshed and a sole remaining candidate is linked" do
    first = payment(date: @ordered_on)
    second = payment(date: @ordered_on + 1.day)
    @purchase.apply_match!
    assert_equal "needs_matching", @purchase.reload.status

    second.destroy!
    perform

    assert_equal first.entryable, @purchase.reload.linked_transaction
  end

  test "receipt purchases are not touched" do
    @purchase.update!(source: :receipt, status: :unmatched)
    payment(date: @ordered_on)

    perform

    assert_equal "unmatched", @purchase.reload.status
  end

  test "one failing purchase doesn't stop the others" do
    other = Purchase.create!(family: @purchase.family, user: @purchase.user, source: :email, status: :awaiting_payment,
                             ordered_on: @ordered_on, total: BigDecimal("12.00"), currency: "USD")
    payment(date: @ordered_on, amount: BigDecimal("12.00"))
    # Fails for the first purchase it checks; the second must still be checked.
    Purchase::Matcher.any_instance.expects(:result).twice
      .raises(StandardError, "boom").then.returns(Purchase::Matcher::Result.new(kind: :none, entries: []))

    assert_nothing_raised { perform }
    assert DebugLogEntry.exists?(source: "Purchase::MatchPendingJob")
    assert other.reload.status.in?(%w[awaiting_payment matched])
  end

  private
    def perform
      Purchase::MatchPendingJob.perform_now
    end

    def payment(date:, amount: BigDecimal("249.99"))
      create_transaction(account: accounts(:depository), date:, amount:, currency: "USD", name: "AMAZON MKTP")
    end
end
