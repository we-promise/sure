# Transactional behavior fixtures replace only the physical session permit.
# Source reloads, ownership checks and publication savepoints still execute.
# MercuryItem::LegacyAccessTest uses real commits and does not include this.
module MercuryFixtureFenceHelper
  def run
    fence = Provider::AccountData::LegacyWriterFence
    original = fence.method(:with_item)
    fixture_permit = lambda do |item, operation: :ingest, &block|
      held = ActiveSupport::IsolatedExecutionState[fence::CONTEXT_KEY]
      if held || !item.is_a?(MercuryItem)
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
    fence.stub(:with_item, fixture_permit) { super }
  end
end
