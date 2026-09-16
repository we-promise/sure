# Transactional fixtures replace the physical session permit and transport's
# outside-transaction assertion; dedicated admission suites retain both checks.
# Source reloads, ownership checks and publication savepoints still execute.
# EnableBankingItem::AdmissionTest uses real commits and does not include this.
module EnableBankingFixtureFenceHelper
  def run
    fence = Provider::AccountData::LegacyWriterFence
    original = fence.method(:with_item)
    original_exclusive = fence.method(:with_exclusive)
    fixture_permit = lambda do |item, operation: :ingest, &block|
      held = ActiveSupport::IsolatedExecutionState[fence::CONTEXT_KEY]
      if held || !item.is_a?(EnableBankingItem)
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
    fixture_exclusive = lambda do |item, &block|
      held = ActiveSupport::IsolatedExecutionState[fence::CONTEXT_KEY]
      if held || !item.is_a?(EnableBankingItem)
        original_exclusive.call(item, &block)
      else
        begin
          ActiveSupport::IsolatedExecutionState[fence::CONTEXT_KEY] = {
            members: { [ item.class.base_class.name, item.id, item.family_id ] => { source: nil } },
            mode: :exclusive, database: ApplicationRecord.connection
          }
          original_exclusive.call(item, &block)
        ensure
          ActiveSupport::IsolatedExecutionState.delete(fence::CONTEXT_KEY)
        end
      end
    end
    fence.stub(:with_item, fixture_permit) do
      EnableBankingItem::LegacyAccess.stub(:assert_transport!, nil) do
        fence.stub(:with_exclusive, fixture_exclusive) { super }
      end
    end
  end
end
