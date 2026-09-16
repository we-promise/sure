require "test_helper"
require_relative "../support/retained_account_index_test_helper"

class ProviderMigrationAccountBindingTest < ActiveSupport::TestCase
  include RetainedAccountIndexTestHelper
  self.use_transactional_tests = false

  Receipt = ProviderMigrationAccountBinding
  Index = Provider::AccountData::RetainedAccountIndex

  setup do
    DebugLogEntry.stubs(:capture)
    Family.any_instance.stubs(:broadcast_refresh)
  end

  test "the verified receipt keeps historical UUIDs after its live account and join have been removed" do
    with_retained_account_copy do |context|
      receipt = retained_receipt(context)
      original = receipt.attributes
      delegated = context.account.accountable
      context.link.delete
      context.account.delete

      assert_not AccountProvider.exists?(receipt.account_provider_id)
      assert_not Account.exists?(receipt.financial_account_id)
      assert receipt.reload.valid?
      assert_equal original, receipt.attributes
      assert_equal receipt.id, Index.verify!(mapping: context.mapping).id
      assert_equal [ receipt.id ], Index.for_account(context.account).pluck(:id)
    ensure
      delegated&.destroy! if context.account.destroyed?
    end
  end

  test "receipt identities and timestamps are immutable through Active Record and direct SQL" do
    with_retained_account_copy do |context|
      receipt = retained_receipt(context)
      original = receipt.attributes
      [ { financial_account_id: SecureRandom.uuid }, { account_provider_id: SecureRandom.uuid },
        { chunk_count: receipt.chunk_count + 1 }, { created_at: receipt.created_at + 1.second } ].each do |change|
        assert_raises(ActiveRecord::RecordInvalid) { receipt.update!(change) }
        assert_equal original, receipt.reload.attributes
        assert_raises(ActiveRecord::StatementInvalid) do
          Receipt.transaction(requires_new: true) { Receipt.where(id: receipt.id).update_all(change) }
        end
        assert_equal original, receipt.reload.attributes
      end
      assert_equal 1, Receipt.where(id: receipt.id).update_all(binding_state: receipt.binding_state)
      assert_equal original, receipt.reload.attributes
    end
  end

  test "duplicate archive receipts are rejected without replacing the original first chunk" do
    with_retained_account_copy do |context|
      receipt = retained_receipt(context)
      original = receipt.attributes
      assert_raises(ActiveRecord::RecordNotUnique) do
        Receipt.transaction(requires_new: true) do
          Receipt.insert_all!([ original.merge("id" => SecureRandom.uuid) ])
        end
      end
      assert_equal original, receipt.reload.attributes
      assert_equal 1, Receipt.where(provider_migration_mapping_id: context.mapping.id).count
    end
  end

  test "linked and unlinked shape and archive count constraints apply to callback-free inserts" do
    with_retained_account_copy do |context|
      receipt = retained_receipt(context)
      invalid = [
        { binding_state: "linked", financial_account_id: nil },
        { binding_state: "linked", account_provider_id: nil },
        { binding_state: "unlinked" },
        { binding_state: "unknown" },
        { chunk_count: 0 }, { chunk_count: 1025 },
        { source_checksum: "not-a-checksum" }
      ]
      invalid.each { |change| assert_rejected_insert(receipt, change) }
    end
    with_retained_account_copy(linked: false) do |context|
      receipt = retained_receipt(context)
      assert_rejected_insert(receipt, financial_account_id: SecureRandom.uuid)
      assert_rejected_insert(receipt, account_provider_id: SecureRandom.uuid)
    end
  end

  test "foreign mapping or family cannot borrow another archive first chunk" do
    with_retained_account_copy do |context|
      with_retained_account_copy do |foreign|
        receipt = retained_receipt(context)
        assert_rejected_insert(receipt, family_id: foreign.family.id)
        assert_rejected_insert(receipt, provider_migration_mapping_id: foreign.mapping.id)
        assert_rejected_insert(receipt, provider_migration_mapping_id: foreign.mapping.id, family_id: foreign.family.id)
        assert_rejected_insert(receipt, first_batch_id: retained_receipt(foreign).first_batch_id)
      end
    end
  end

  test "another mapping in the same connection and a nonzero chunk cannot replace the archive owner" do
    with_retained_account_copy do |context|
      other = context.item.up_accounts.create!(name: "Another source", currency: "USD", account_id: SecureRandom.uuid)
      finish_retained_shadow_copy(context.copier)
      mapping = context.control.provider_migration_mappings.find_by!(role: "external_account", legacy_id: other.id)
      receipt = retained_receipt(context)
      other_receipt = Receipt.find_by!(provider_migration_mapping_id: mapping.id)

      assert_rejected_insert(receipt, provider_migration_mapping_id: mapping.id)
      assert_rejected_insert(receipt, first_batch_id: other_receipt.first_batch_id)
      assert_rejected_insert(receipt, first_batch_id: retained_chunks(context).second.id)
      connection_mapping = context.control.provider_migration_mappings.find_by!(role: "connection")
      assert_rejected_insert(receipt, provider_migration_mapping_id: connection_mapping.id)
    end
  end

  test "database owner guard checks actual first chunk stream scope sequence and archive key" do
    with_retained_account_copy do |context|
      receipt = retained_receipt(context)
      first = retained_chunks(context).first
      changes = [
        { stream: "other_snapshot" }, { scope_key: "UpAccount:#{SecureRandom.uuid}" },
        { sequence: 1 }, { idempotency_key: "migration:wrong-owner" }, { external_account_id: nil }
      ]
      changes.each do |change|
        Receipt.transaction(requires_new: true) do
          Receipt.where(id: receipt.id).delete_all
          IngestionBatch.where(id: first.id).update_all(change)
          candidate = Receipt.new(receipt.attributes.merge("id" => SecureRandom.uuid))
          assert_not candidate.valid?
          assert candidate.errors[:first_batch].present?
          assert_raises(ActiveRecord::StatementInvalid) { Receipt.insert_all!([ candidate.attributes ]) }
          raise ActiveRecord::Rollback
        end
        assert Receipt.exists?(receipt.id)
      end
    end
  end

  test "retained mapping and first chunk cannot be removed ahead of their receipt" do
    with_retained_account_copy do |context|
      receipt = retained_receipt(context)
      [ context.mapping, receipt.first_batch ].each do |record|
        assert_raises(ActiveRecord::InvalidForeignKey) do
          Receipt.transaction(requires_new: true) { record.class.where(id: record.id).delete_all }
        end
        assert record.class.exists?(record.id)
      end
      assert_equal receipt.id, Index.verify!(mapping: context.mapping).id
    end
  end

  test "the database guard is present when the acceptance database is prepared" do
    database = ApplicationRecord.connection
    count = database.select_value(<<~SQL)
      SELECT COUNT(*) FROM pg_trigger
      WHERE tgrelid = 'provider_migration_account_bindings'::regclass
        AND tgname = 'provider_migration_account_binding_guard'
        AND NOT tgisinternal AND tgenabled = 'O'
    SQL
    assert_equal 1, count.to_i, "Acceptance requires the migration-created reverse-index guard, not only schema.rb tables"
  end

  private

    def assert_rejected_insert(receipt, changes)
      original = receipt.reload.attributes
      candidate = Receipt.new(original.merge(changes.stringify_keys).merge("id" => SecureRandom.uuid))
      assert_not candidate.valid?
      # Remove the original only inside the rollback savepoint so uniqueness
      # cannot accidentally stand in for the ownership/check constraint tested.
      Receipt.transaction(requires_new: true) do
        Receipt.where(id: receipt.id).delete_all
        assert_raises(ActiveRecord::StatementInvalid) { Receipt.insert_all!([ candidate.attributes ]) }
        raise ActiveRecord::Rollback
      end
      assert_equal original, receipt.reload.attributes
    end
end
