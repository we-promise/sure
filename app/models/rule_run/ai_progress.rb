# For an Ai::Requester that runs on a family's transactions, from a rule run or not: built from the
# job's window of its Ai::GenerationRun, it reports each batch to the RuleRun as it lands, so the
# run's progress moves per batch, and releases what no batch reported when the job ends, including
# the ids no job has read yet when the run gives up. Expects `scope_for(ids)`, those of the ids it
# would send.
module RuleRun::AiProgress
  extend ActiveSupport::Concern

  class_methods do
    def from_ai_job(window:, family_id:, rule_run_id: nil)
      new(Family.find(family_id), window:, rule_run: (RuleRun.find_by(id: rule_run_id) if rule_run_id))
    end

    # Ai::ShadowJob's: the transactions the primary was sent.
    def from_shadow_job(ids:, family_id:) = new(Family.find(family_id), transaction_ids: ids)
  end

  # transaction_ids: the transactions to work on, when there's no window (a shadow run, a test).
  def initialize(family, transaction_ids: [], window: nil, rule_run: nil)
    @family = family
    @transaction_ids = transaction_ids
    @window = window
    @rule_run = rule_run
  end

  def ai_correlation_id = @rule_run ? "rule_run:#{@rule_run.id}" : nil

  # The modified counts reached the run per batch (apply_ai); this releases the rest.
  def ai_finished(_count)
    release_unhandled
    @rule_run&.complete_job!
  end

  private
    attr_reader :family

    # This job's transactions: every id its window has examined, matching or not, so the ones
    # dropped count as handled. Read live, so a window that raised partway still counts what it read.
    def transaction_ids
      return @transaction_ids unless @window

      matching_transaction_ids unless @window.taken?
      @window.examined_ids
    end

    # The ids this job sends: those of its window that `scope_for` keeps.
    def matching_transaction_ids
      @matching_transaction_ids ||=
        if @window
          @window.take_matching { |chunk| scope_for(chunk).pluck(:id) }
        else
          scope_for(transaction_ids).pluck(:id)
        end
    end

    # From apply_ai, inside its transaction: the batch's transactions are handled, and `modified`
    # of them changed. Counted as reported only once that commits; a batch that fails to record or
    # rolls back is left for release_unhandled.
    def report_batch(result, modified:)
      handled = transaction_ids.size - result.remaining.size
      @rule_run&.ai_handled!(handled:, modified:)
      ActiveRecord.after_all_transactions_commit { @handled = handled }
    end

    # From ai_finished and ai_failed: this job's transactions that no batch reported, and the run's
    # ids no job read. Once: ai_failed after a failed ai_finished releases nothing more.
    def release_unhandled
      return if @released

      @rule_run&.ai_handled!(handled: transaction_ids.size - @handled.to_i + @window&.outstanding.to_i)
      @released = true
    end

    # Only those of `ids` this job's transactions include: an answer naming any other is ignored.
    def decided(ids) = ids & transaction_ids

    def transactions_input(transactions)
      transactions.map do |transaction|
        {
          id: transaction.id,
          amount: transaction.entry.amount.abs,
          classification: transaction.entry.classification,
          description: [ transaction.entry.name, transaction.entry.notes ].compact.reject(&:empty?).join(" "),
          merchant: transaction.merchant&.name
        }
      end
    end
end
