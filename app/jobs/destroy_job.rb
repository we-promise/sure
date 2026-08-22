class DestroyJob < ApplicationJob
  queue_as :low_priority
  # Inherits enqueue_after_transaction_commit = true from ApplicationJob. (This
  # previously read `= :never`, the removed Rails 7.2 symbol API; under 8.1 that
  # symbol is truthy, so it already deferred — the explicit line was dead and
  # misleading.) Deferring is correct here: destroy after the enclosing
  # transaction commits, never against an uncommitted/rolled-back record.

  def perform(model)
    model.destroy
  rescue => e
    model.update!(scheduled_for_deletion: false) if model.respond_to?(:scheduled_for_deletion) # Let's the user try again by resetting the state
  end
end
