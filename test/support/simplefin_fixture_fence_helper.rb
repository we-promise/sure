# Existing financial behavior examples use fixture transactions. Substitute only
# the physical session permit; ownership reloads, source subsets and Sync checks
# still run. Real admission/concurrency is covered in separate nontransactional
# SimpleFIN legacy access, processor and job tests, without this helper.
module SimplefinFixtureFenceHelper
  def run
    fence = Provider::AccountData::LegacyWriterFence
    original = fence.method(:with_item)
    fixture_permit = lambda do |item, operation: :ingest, &block|
      held = ActiveSupport::IsolatedExecutionState[fence::CONTEXT_KEY]
      if held || !item.is_a?(SimplefinItem)
        original.call(item, operation: operation, &block)
      else
        begin
          ActiveSupport::IsolatedExecutionState[fence::CONTEXT_KEY] = {
            members: { [ item.class.base_class.name, item.id, item.family_id ] => { source: nil } },
            mode: :shared, database: ApplicationRecord.connection
          }
          original.call(item, operation: operation, &block)
        ensure
          ActiveSupport::IsolatedExecutionState.delete(fence::CONTEXT_KEY)
        end
      end
    end
    # Existing transactional financial examples do not exercise physical session
    # locking. The real-commit credential and admission suites use both locks.
    credential_permit = ->(target_type:, target_id:, &block) { block.call }
    request_permit = ->(provider_key:, request_fingerprint:, &block) { block.call }
    ProviderCredentialClaim.stub(:with_target_lock, credential_permit) do
      ProviderCredentialClaim.stub(:with_request_lock, request_permit) do
        fence.stub(:with_item, fixture_permit) { super }
      end
    end
  end
end
