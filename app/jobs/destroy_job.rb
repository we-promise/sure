class DestroyJob < ApplicationJob
  queue_as :low_priority
  # Inherits enqueue_after_transaction_commit = true from ApplicationJob. (This
  # previously read `= :never`, the removed Rails 7.2 symbol API; under 8.1 that
  # symbol is truthy, so it already deferred — the explicit line was dead and
  # misleading.) Deferring is correct here: destroy after the enclosing
  # transaction commits, never against an uncommitted/rolled-back record.

  def perform(model)
    fence = Provider::AccountData::LegacyWriterFence
    if fence.legacy_item?(model)
      fence.with_item(model, operation: :lifecycle) { |current| destroy_and_recover(current) }
    elsif fence.legacy_account?(model)
      fence.with_account(model, operation: :lifecycle) { |current| destroy_and_recover(current) }
    else
      destroy_and_recover(model)
    end
  end

  private
    def destroy_and_recover(model)
      model.destroy
    rescue Provider::AccountData::LegacyWriterFence::Busy, Provider::AccountData::LegacyWriterFence::OwnershipChanged,
        Provider::AccountData::LegacyWriterFence::InvalidSource
      # Refused admission must never reopen the source's deletion state.
      raise
    rescue StandardError
      # Recovery uses the admitted receiver and retains its lifecycle permit
      # after a model's nested destroy permit or transaction has unwound.
      model.update!(scheduled_for_deletion: false) if model.respond_to?(:scheduled_for_deletion)
    end
end
