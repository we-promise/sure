# For an Ai::Requester that runs on a family's transactions, from a rule run or not: built from the
# job's ids, it reports each batch to the RuleRun as it lands, so the run's progress moves per
# batch, and releases what no batch reported when the job ends. Expects `scope`, this job's
# transactions with their entries.
module RuleRun::AiProgress
  extend ActiveSupport::Concern

  class_methods do
    def from_ai_job(ids:, family_id:, rule_run_id: nil)
      new(Family.find(family_id), transaction_ids: ids, rule_run: (RuleRun.find_by(id: rule_run_id) if rule_run_id))
    end
  end

  def initialize(family, transaction_ids: [], rule_run: nil)
    @family = family
    @transaction_ids = transaction_ids
    @rule_run = rule_run
  end

  def ai_correlation_id = @rule_run ? "rule_run:#{@rule_run.id}" : nil

  # The modified counts reached the run per batch (apply_ai); this releases the rest.
  def ai_finished(_count)
    release_unhandled
    @rule_run&.complete_job!
  end

  private
    attr_reader :family, :transaction_ids

    # From apply_ai, inside its transaction: the batch's transactions are handled, and `modified`
    # of them changed. Counted as reported only once that commits; a batch that fails to record or
    # rolls back is left for release_unhandled.
    def report_batch(result, modified:)
      handled = transaction_ids.size - result.remaining.size
      @rule_run&.ai_handled!(handled:, modified:)
      ActiveRecord.after_all_transactions_commit { @handled = handled }
    end

    # From ai_finished and ai_failed: this job's transactions that no batch reported.
    def release_unhandled
      @rule_run&.ai_handled!(handled: transaction_ids.size - @handled.to_i)
      @handled = transaction_ids.size   # released once: ai_failed after a failed ai_finished releases nothing more
    end

    def transactions_input(transactions = scope)
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
