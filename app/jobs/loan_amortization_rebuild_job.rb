# Rebuilds a loan's persisted amortization schedule off the request/save path.
# Delegates to Loan#ensure_amortization_schedule_current!, which is a no-op if
# something else (e.g. the account page's lazy build) already rebuilt it first.
class LoanAmortizationRebuildJob < ApplicationJob
  queue_as :low_priority
  sidekiq_options lock: :until_executed, lock_args_method: ->(args) { [ args.first ] }, on_conflict: :log

  def perform(loan_id)
    loan = Loan.find_by(id: loan_id)
    loan&.ensure_amortization_schedule_current!
  end
end
