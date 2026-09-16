require "test_helper"
require "timeout"
require_relative "../support/provider_ingestion_test_helper"

class DestroyJobLegacyAdmissionTest < ActiveJob::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  Fence = Provider::AccountData::LegacyWriterFence

  test "ordinary recovery uses the fresh item while its permit excludes another session's drain" do
    with_source do |item, _account|
      stale = UpItem.find(item.id)
      stale.name = "Unreviewed stale caller edit"
      admitted = nil
      recovery_checks = 0
      UpItem.any_instance.expects(:destroy).with do
        admitted = admitted_source(item)
        assert_not_same stale, admitted
        assert_equal "Queued legacy deletion", admitted.name
        assert_equal 0, ApplicationRecord.connection.open_transactions
        true
      end.raises(IOError, "Ordinary destroy failure")
      observer = lambda do |_name, _started, _finished, _unique_id, payload|
        next unless payload[:sql].match?(/\AUPDATE "up_items"/i)

        recovery_checks += 1
        assert_same admitted, admitted_source(item)
        assert_equal :busy, in_another_session { try_drain(item) }
      end

      ActiveSupport::Notifications.subscribed(observer, "sql.active_record") { DestroyJob.perform_now(stale) }

      assert_equal 1, recovery_checks
      assert_not item.reload.scheduled_for_deletion?
      assert_equal "Queued legacy deletion", item.name
      assert stale.scheduled_for_deletion?
      assert_equal "Unreviewed stale caller edit", stale.name
      assert_equal :drained, in_another_session { try_drain(item) }
    end
  end

  test "a provider account is destroyed through its current parent permit using a fresh receiver" do
    with_source do |item, account|
      stale = UpAccount.find(account.id)
      stale.expects(:destroy).never
      deletion_checks = 0
      observer = lambda do |_name, _started, _finished, _unique_id, payload|
        next unless payload[:sql].match?(/\ADELETE FROM "up_accounts"/i)

        deletion_checks += 1
        assert_equal item.id, admitted_source(item).id
        assert_equal :busy, in_another_session { try_drain(item) }
      end

      assert_difference "UpAccount.count", -1 do
        ActiveSupport::Notifications.subscribed(observer, "sql.active_record") { DestroyJob.perform_now(stale) }
      end

      assert_equal 1, deletion_checks
      assert item.reload.scheduled_for_deletion?
      assert_equal :drained, in_another_session { try_drain(item) }
    end
  end

  test "an ordinary account failure retains the existing no-deletion-flag behavior inside admission" do
    with_source do |item, account|
      stale = UpAccount.find(account.id)
      stale.expects(:destroy).never
      UpAccount.any_instance.expects(:destroy).with do
        assert_equal item.id, admitted_source(item).id
        assert_equal 0, ApplicationRecord.connection.open_transactions
        true
      end.raises(IOError, "Ordinary account failure")
      before = account.attributes

      queries = capture_sql_queries { assert_nil DestroyJob.perform_now(stale) }

      assert_empty queries.grep(/\A(?:INSERT|UPDATE|DELETE)\b/i)
      assert_equal before, account.reload.attributes
      assert item.reload.scheduled_for_deletion?
    end
  end

  test "quiescing and native ownership deny both item and account destruction without clearing the flag" do
    UpItem.any_instance.expects(:destroy).never
    UpAccount.any_instance.expects(:destroy).never
    with_source do |item, account|
      control = ProviderMigrationControl.create!(family: item.family, provider_key: "up", legacy_type: "UpItem", legacy_id: item.id)
      %w[quiescing active retired rollback_pending].each do |state|
        control.update!(state: state)
        original = [ item.reload.attributes, account.reload.attributes, control.reload.attributes ]
        queries = capture_sql_queries do
          [ item, account ].each do |model|
            assert_raises(Fence::OwnershipChanged) { DestroyJob.perform_now(model) }
          end
        end

        assert_empty queries.grep(/\A(?:INSERT|UPDATE|DELETE)\b/i)
        assert_equal original, [ item.reload.attributes, account.reload.attributes, control.reload.attributes ]
        assert item.scheduled_for_deletion?
      end
    end
  end

  test "an exclusive drain refuses queued item and account work in another database session" do
    with_source do |item, account|
      before = [ item.attributes, account.attributes ]
      Fence.with_exclusive(item) do
        [ item, account ].each do |model|
          result = in_another_session do
            DestroyJob.perform_now(model)
            :unexpected_destroy
          rescue Fence::Busy
            :busy
          end
          assert_equal :busy, result
        end
      end

      assert_equal before, [ item.reload.attributes, account.reload.attributes ]
      assert item.scheduled_for_deletion?
    end
  end

  test "invalid legacy source objects cannot fall through to ordinary destruction or flag recovery" do
    item = UpItem.new(family: families(:dylan_family), name: "Unpersisted item", access_token: "private-token", scheduled_for_deletion: true)
    account = UpAccount.new(up_item: item, name: "Unpersisted account", currency: "AUD")
    [ item, account ].each do |model|
      model.expects(:destroy).never
      model.expects(:update!).never

      assert_raises(Fence::InvalidSource) { DestroyJob.perform_now(model) }
    end
    assert item.scheduled_for_deletion?
  end

  test "fence errors raised during an admitted destroy escape without ordinary failure recovery" do
    with_source do |item, _account|
      [ Fence::Busy, Fence::OwnershipChanged, Fence::InvalidSource ].each do |error_class|
        failure = error_class.new("Refused nested lifecycle operation")
        UpItem.any_instance.stubs(:destroy).raises(failure)
        before = item.reload.attributes

        queries = capture_sql_queries do
          assert_same failure, assert_raises(error_class) { DestroyJob.perform_now(item) }
        end

        assert_empty queries.grep(/\A(?:INSERT|UPDATE|DELETE)\b/i)
        assert_equal before, item.reload.attributes
        assert item.scheduled_for_deletion?
      end
    end
  end

  test "legacy account detection includes each reviewed manifest and excludes financial and native models" do
    Provider::AccountData::MigrationManifest.all.each do |manifest|
      assert Fence.legacy_account?(manifest.account_type.constantize.new), manifest.provider_key
      assert_not Fence.legacy_account?(manifest.item_type.constantize.new), manifest.provider_key
    end
    assert_not Fence.legacy_account?(Account.new)
    assert_not Fence.legacy_account?(ExternalAccount.new)
    assert_not Fence.legacy_account?(ProviderConnection.new)
    assert_not Fence.legacy_account?(Object.new)
  end

  private
    def admitted_source(item)
      ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY].fetch(:members)
        .fetch([ item.class.base_class.name, item.id, item.family_id ]).fetch(:source)
    end

    def with_source
      with_provider_encryption do
        item = UpItem.create!(family: families(:dylan_family), name: "Queued legacy deletion", access_token: "private-up-token",
          scheduled_for_deletion: true)
        account = item.up_accounts.create!(account_id: SecureRandom.uuid, name: "Checking", currency: "AUD")
        begin
          yield item, account
        ensure
          ProviderMigrationControl.where(legacy_type: "UpItem", legacy_id: item.id).delete_all
          UpAccount.where(up_item_id: item.id).delete_all
          item.delete
        end
      end
    end

    def try_drain(item)
      Fence.with_exclusive(item) { :drained }
    rescue Fence::Busy
      :busy
    end

    def in_another_session(&block)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      worker = Thread.new do
        ApplicationRecord.connection_pool.with_connection(&block)
      end
      Timeout.timeout(5) { worker.value }
    ensure
      worker&.kill if worker&.alive?
      worker&.join
    end
end
