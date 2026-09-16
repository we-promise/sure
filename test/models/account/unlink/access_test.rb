require "test_helper"
require "timeout"
require_relative "../../../support/provider_ingestion_test_helper"

class Account::Unlink::AccessTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  Access = Account::Unlink::Access
  Fence = Provider::AccountData::LegacyWriterFence
  Context = Data.define(:family, :account, :connection, :external, :link)

  setup do
    DebugLogEntry.stubs(:capture)
    Family.any_instance.stubs(:broadcast_refresh)
  end

  test "native admission yields a fresh locked owner and immutable unlink disposition" do
    with_native_account do |context|
      before = context.account.attributes

      Access.with_account(context.account) do |current, disposition|
        assert_not_same context.account, current
        assert_equal context.account.id, current.id
        assert_operator ApplicationRecord.connection.open_transactions, :>, 0
        assert_equal [ context.link.id ], disposition.native_link_ids
        assert_empty disposition.preserved_legacy_sources
        assert disposition.frozen?
        assert disposition.native_link_ids.frozen?
        assert disposition.preserved_legacy_sources.frozen?
      end

      assert_equal before, context.account.reload.attributes
      assert AccountProvider.exists?(context.link.id)
      assert_nil ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
      assert_equal 0, ApplicationRecord.connection.open_transactions
    end
  end

  test "a native connection held by another session refuses admission without yielding" do
    with_native_account do |context|
      before = context.account.attributes
      original_link = context.link.attributes

      with_row_lock(context.connection) do
        assert_raises(Fence::Busy) do
          Access.with_account(context.account) { flunk "Busy source must not enter unlink work" }
        end
        assert_equal before, context.account.reload.attributes
        assert_equal original_link, context.link.reload.attributes
        assert_nil ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
        assert_equal 0, ApplicationRecord.connection.open_transactions
      end

      yielded = false
      Access.with_account(context.account) { yielded = true }
      assert yielded, "The failed admission must release its transaction and permit"
    end
  end

  test "a native link moved between the initial inventory and locking cannot be unlinked by the old owner" do
    with_native_account do |context|
      replacement = context.family.accounts.create!(name: "New financial owner", balance: 0, currency: "USD", accountable: Depository.new)
      original_account = context.account.attributes
      access = changing_inventory(context.account) { context.link.update!(account: replacement) }

      assert_raises(Fence::OwnershipChanged) do
        access.with_account { flunk "Changed link ownership must restart admission" }
      end

      assert_equal replacement.id, context.link.reload.account_id
      assert_equal original_account, context.account.reload.attributes
      assert_nil ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
    end
  end

  test "a newly linked native source cannot silently widen the original inventory" do
    with_native_account do |context|
      added_link = nil
      original_account = context.account.attributes
      access = changing_inventory(context.account) do
        connection = create_provider_connection(family: context.family, provider_key: "up")
        external = create_external_account(connection)
        added_link = AccountProvider.create!(account: context.account, external_account: external)
      end

      assert_raises(Fence::OwnershipChanged) do
        access.with_account { flunk "An additional source requires a fresh complete inventory" }
      end

      assert_equal [ context.link.id, added_link.id ].sort, context.account.account_providers.pluck(:id).sort
      assert_equal original_account, context.account.reload.attributes
      assert_nil ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
    end
  end

  test "a transitional copied owner refuses the complete mixed-source operation" do
    with_native_account do |context|
      _item, _source, copied_link, control = copied_up_source(context)
      before = context.account.reload.attributes
      %w[quiescing rollback_pending].each do |state|
        control.update!(state: state)

        assert_raises(Fence::OwnershipChanged) do
          Access.with_account(context.account) { flunk "A changing writer cannot admit any member" }
        end

        assert_equal before, context.account.reload.attributes
        assert_equal [ context.link.id, copied_link.id ].sort, context.account.account_providers.pluck(:id).sort
        assert_nil ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
      end
    end
  end

  test "mixed legacy and native owners receive the complete permit and exact preserved source disposition" do
    with_native_account do |context|
      copied_item, copied_source, copied_link, control = copied_up_source(context)
      legacy_item, legacy_source, legacy_link = plaid_source(context)
      context.account.update!(plaid_account: legacy_source)

      # These are ownership fixtures, not a provider activation operation. The
      # copied connection stays disabled and no provider work is scheduled.
      %w[shadow active retired].each do |state|
        control.update!(state: state)
        native_copy = ProviderMigrationControl::NATIVE_STATES.include?(state)
        before = context.account.reload.attributes

        Access.with_account(context.account) do |current, disposition|
          assert_equal legacy_source.id, current.plaid_account_id
          assert_equal [ context.link.id, copied_link.id, legacy_link.id ].sort, current.account_providers.pluck(:id).sort
          Fence.with_item(legacy_item, operation: :lifecycle) { |fresh| assert_equal legacy_item.id, fresh.id }
          if native_copy
            assert_equal [ context.link.id, copied_link.id ].sort, disposition.native_link_ids.sort
            assert_equal [ [ "UpAccount", copied_source.id ] ], disposition.preserved_legacy_sources
            assert_raises(ArgumentError) do
              Fence.with_item(copied_item, operation: :lifecycle) { flunk "Native compatibility rows are not legacy permits" }
            end
          else
            assert_equal [ context.link.id ], disposition.native_link_ids
            assert_empty disposition.preserved_legacy_sources
            Fence.with_item(copied_item, operation: :lifecycle) { |fresh| assert_equal copied_item.id, fresh.id }
          end
        end

        assert_equal before, context.account.reload.attributes
        assert control.provider_connection.reload.disabled?
        assert_nil ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
      end
    end
  end

  test "failed work rolls back its savepoint while an admitted outer caller can continue" do
    with_native_account do |context|
      original_name = context.account.name
      original_link = context.link.attributes

      Account.transaction do
        assert_raises(RuntimeError) do
          Access.with_account(context.account) do |current, _disposition|
            current.update!(name: "Uncommitted unlink work")
            current.account_providers.find(context.link.id).destroy!
            raise "Failure after local mutation"
          end
        end
        Account.where(id: context.account.id).update_all(notes: "Outer transaction continued")
      end

      assert_equal original_name, context.account.reload.name
      assert_equal "Outer transaction continued", context.account.notes
      assert_equal original_link, context.link.reload.attributes
      assert ExternalAccount.exists?(context.external.id)
      assert_nil ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
    end
  end

  private
    def with_native_account
      with_provider_encryption do
        family = Family.create!(name: "Unlink admission fixture")
        begin
          account = family.accounts.create!(name: "Shared financial account", balance: "12.34", currency: "USD", accountable: Depository.new)
          connection = create_provider_connection(family: family, provider_key: "monobank")
          external = create_external_account(connection)
          link = AccountProvider.create!(account: account, external_account: external)
          yield Context.new(family, account, connection, external, link)
        ensure
          cleanup_family(family)
          clear_enqueued_jobs
        end
      end
    end

    def copied_up_source(context)
      item = UpItem.create!(family: context.family, name: "Copied source", access_token: "private-unlink-source")
      source = item.up_accounts.create!(account_id: SecureRandom.uuid, name: "Checking", currency: "USD", current_balance: "12.34", raw_transactions_payload: [])
      link = AccountProvider.create!(account: context.account, provider: source)
      copier = Provider::AccountData::MigrationCopier.new(provider_key: "up", legacy_item_id: item.id, batch_size: 1)
      control = nil
      15.times do
        control = copier.run.reload
        break if control.shadow?
      end
      assert control.shadow?
      assert link.reload.external_account_id
      [ item, source, link, control ]
    end

    def plaid_source(context)
      item = PlaidItem.create!(family: context.family, name: "Legacy source", access_token: "private-unlink-plaid",
        plaid_id: SecureRandom.uuid, plaid_region: "eu")
      source = item.plaid_accounts.create!(plaid_id: SecureRandom.uuid, name: "Checking", currency: "USD", plaid_type: "depository", current_balance: 1)
      link = AccountProvider.create!(account: context.account, provider: source)
      [ item, source, link ]
    end

    def changing_inventory(account, &change)
      Class.new(Access) do
        define_method(:initialize) do |selected|
          super(selected)
          @change_once = change
        end

        private
          def snapshot
            captured = super
            change = @change_once
            @change_once = nil
            change&.call
            captured
          end
      end.new(account)
    end

    def with_row_lock(record)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      entered, release = Queue.new, Queue.new
      worker = Thread.new do
        begin
          ApplicationRecord.connection_pool.with_connection do
            record.class.transaction do
              record.class.where(id: record.id).select(:id).lock("FOR UPDATE").first!
              entered << true
              release.pop
            end
          end
        rescue StandardError => error
          entered << error
          raise
        end
      end
      worker.report_on_exception = false
      observed = Timeout.timeout(5) { entered.pop }
      raise observed if observed.is_a?(Exception)
      yield
    ensure
      release << true if release
      begin
        Timeout.timeout(5) { worker.value } if worker
      ensure
        worker&.kill if worker&.alive?
        worker&.join
      end
    end

    def cleanup_family(family)
      # All records belong to this new family. Remove test-created archive
      # receipts before their referenced parents; never disable database guards.
      accounts = Account.where(family_id: family.id)
      Account::SourcePolicy.where(family_id: family.id).delete_all
      AccountProvider.where(account_id: accounts.select(:id)).delete_all
      Account.where(family_id: family.id).update_all(plaid_account_id: nil, simplefin_account_id: nil)
      ProviderMigrationAccountBinding.where(family_id: family.id).delete_all
      ProviderSyncCheckpoint.where(family_id: family.id).delete_all
      IngestionBatch.where(family_id: family.id).delete_all
      ProviderMigrationMapping.where(family_id: family.id).delete_all
      ProviderMigrationControl.where(family_id: family.id).delete_all
      ProviderConnection.where(family_id: family.id).each(&:destroy!)
      accounts.each(&:destroy!)
      UpAccount.where(up_item_id: UpItem.where(family_id: family.id).select(:id)).delete_all
      PlaidAccount.where(plaid_item_id: PlaidItem.where(family_id: family.id).select(:id)).delete_all
      UpItem.where(family_id: family.id).delete_all
      PlaidItem.where(family_id: family.id).delete_all # No remote deletion in fixture cleanup.
      family.reload.destroy!
    end
end
