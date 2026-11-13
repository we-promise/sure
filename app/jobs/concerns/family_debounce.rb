# Debounces a job per family. Every schedule stores a fresh token in the
# cache, and only the run carrying the stored token proceeds. Unlike a
# timestamp, a token cannot tie with another schedule or be outranked by a
# cache write that lands out of order.
module FamilyDebounce
  extend ActiveSupport::Concern

  included do
    class_attribute :debounce_key_prefix, instance_writer: false
  end

  class_methods do
    def debounce_key(family_id)
      "#{debounce_key_prefix}:#{family_id}"
    end

    # Enqueues a run with a fresh token once all open transactions committed,
    # and stores that token only when the queue accepted the job. A rolled-back
    # transaction or a failed enqueue therefore never cancels runs that are
    # already waiting. on_failure runs when the job could not be enqueued.
    def enqueue_debounced(family_id, wait:, expires_in:, &on_failure)
      ActiveRecord.after_all_transactions_commit do
        next if enqueue_with_token(family_id, wait: wait, expires_in: expires_in)

        on_failure&.call
      rescue => e
        Rails.logger.error("#{name} debounce fallback failed: #{e.message}\n#{e.backtrace&.join("\n")}")
      end
    end

    private
      def enqueue_with_token(family_id, wait:, expires_in:)
        token = SecureRandom.uuid
        job = set(wait: wait).perform_later(family_id, token)
        return false unless job&.successfully_enqueued?

        Rails.cache.write(debounce_key(family_id), token, expires_in: expires_in)
        true
      rescue => e
        Rails.logger.error("#{name} enqueue failed: #{e.message}\n#{e.backtrace&.join("\n")}")
        false
      end
  end

  private
    # A missing key (expired, or a cache store that keeps nothing) lets the
    # run proceed, so the job degrades to running once per schedule.
    def superseded?(family_id, token)
      latest = Rails.cache.read(self.class.debounce_key(family_id))
      latest.present? && latest != token
    end
end
