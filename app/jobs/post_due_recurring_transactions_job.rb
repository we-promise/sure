class PostDueRecurringTransactionsJob < ApplicationJob
  queue_as :scheduled

  # Iterates every active `RecurringTransaction` flagged `auto_post: true`
  # whose `next_expected_date` has arrived, materializes a real `Entry`
  # via `RecurringTransaction::AutoPoster`, and lets the AutoPoster
  # advance `next_expected_date` forward so the row stops being "due".
  #
  # Scheduled daily via `config/schedule.yml` — see the
  # `post_due_recurring_transactions` entry.
  def perform
    Rails.logger.tagged("PostDueRecurringTransactionsJob") do
      due = RecurringTransaction
        .active
        .where(auto_post: true)
        .where("next_expected_date <= ?", Date.current)

      total = due.count
      posted = 0
      skipped = 0

      Rails.logger.info("Found #{total} recurring transactions due for auto-post")

      due.find_each do |recurring|
        result = RecurringTransaction::AutoPoster.new(recurring).call

        if result.posted?
          posted += 1
        else
          skipped += 1
          Rails.logger.info("Skipped recurring #{recurring.id}: #{result.status} (#{result.reason})")
        end
      rescue StandardError => e
        # Don't let one bad recurring break the whole batch. Sentry will
        # surface it for investigation; the next run picks the row up
        # again if it's still due.
        Sentry.capture_exception(e) do |scope|
          scope.set_tags(recurring_transaction_id: recurring.id)
        end
        skipped += 1
        Rails.logger.error("Failed to auto-post recurring #{recurring.id}: #{e.class}: #{e.message}")
      end

      Rails.logger.info("Auto-post complete: posted=#{posted} skipped=#{skipped} total=#{total}")
    end
  end
end
