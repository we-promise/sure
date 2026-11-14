# For an Ai::Requester that runs on a rule's transactions: reports each batch to the RuleRun as it
# lands, so the run's progress moves per batch, and releases what no batch reported when the job
# ends. Expects `transaction_ids` (this job's) and `@rule_run` (nil outside a rule run).
module RuleRun::AiProgress
  def ai_correlation_id = @rule_run ? "rule_run:#{@rule_run.id}" : nil

  private
    # From apply_ai: the batch's transactions are handled, and `modified` of them changed.
    def report_batch(result, modified:)
      @handled = transaction_ids.size - result.remaining.size
      @rule_run&.ai_handled!(handled: @handled, modified:)
    end

    # From ai_finished and ai_failed: this job's transactions that no batch reported.
    def release_unhandled = @rule_run&.ai_handled!(handled: transaction_ids.size - @handled.to_i)
end
