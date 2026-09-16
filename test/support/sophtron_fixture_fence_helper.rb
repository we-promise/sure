# Existing controller/model examples exercise behavior in fixture transactions.
# Substitute only the session permit; fresh-source, account-subset and Sync
# validation still run. Real lock/admission enforcement belongs in the separate
# nontransactional SophtronItem::LegacyAccessTest and SophtronLegacyJobsTest.
module SophtronFixtureFenceHelper
  def run
    fence = Provider::AccountData::LegacyWriterFence
    admitted = fence.method(:with_item)
    fixture_permit = lambda do |item, operation: :ingest, &block|
      held = ActiveSupport::IsolatedExecutionState[fence::CONTEXT_KEY]
      if held || !item.is_a?(SophtronItem)
        admitted.call(item, operation: operation, &block)
      else
        begin
          ActiveSupport::IsolatedExecutionState[fence::CONTEXT_KEY] = {
            members: { [ item.class.base_class.name, item.id, item.family_id ] => { source: nil } },
            mode: :shared, database: ApplicationRecord.connection
          }
          admitted.call(item, operation: operation, &block)
        ensure
          ActiveSupport::IsolatedExecutionState.delete(fence::CONTEXT_KEY)
        end
      end
    end
    fence.stub(:with_item, fixture_permit) { super }
  end
end
