require "test_helper"
require "timeout"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::MigrationQuiescenceTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  Copier = Provider::AccountData::MigrationCopier
  Fence = Provider::AccountData::LegacyWriterFence

  test "final copy restarts the shadow comparison and preserves original financial identities" do
    with_source do |item, source, copier|
      financial = accounts(:depository)
      link = AccountProvider.create!(account: financial, provider: source)
      before_account = financial.attributes
      before_entries = financial.entries.order(:id).pluck(:id)
      10.times do
        break if copier.run.shadow?
      end
      control = copier.control.reload
      assert control.shadow?
      external_id = link.reload.external_account_id
      Fence.with_item(item) do |current|
        current.update!(access_token: "rotated-before-final-copy")
        source.update!(current_balance: 42)
      end

      first_pass = copier.run_quiesced.reload

      assert first_pass.quiescing?
      assert_empty first_pass.audit_results
      assert_equal "verify", first_pass.high_water_mark.fetch("phase")
      run_id = first_pass.high_water_mark.fetch("copy_run_id")
      assert_equal 42, ExternalAccount.find(external_id).current_balance
      assert_equal "rotated-before-final-copy", first_pass.provider_connection.credentials.fetch("access_token")
      assert_operator first_pass.provider_connection.credential_revision, :>, 0

      # A fresh instance resumes the persisted pass, as a different worker would.
      verified = finish_quiesced(item)
      assert_equal run_id, verified.audit_results.fetch("copy_run_id")
      assert verified.quiescing?
      assert verified.provider_connection.disabled?
      assert verified.audit_results.fetch("declared_writer_fence_held")
      assert_not verified.audit_results.fetch("source_quiesced")
      assert verified.audit_results.fetch("requires_cutover_reverification")
      assert_equal external_id, link.reload.external_account_id
      assert_equal source.id, link.provider_id
      assert_equal "UpAccount", link.provider_type
      assert_equal before_account, financial.reload.attributes
      assert_equal before_entries, financial.entries.order(:id).pluck(:id)
      assert_equal source.id, link.effective_provider.id
      assert_raises(Fence::OwnershipChanged) { Fence.with_item(item) { flunk "Copy success must keep legacy paused" } }
    end
  end

  test "an admitted legacy writer prevents quiescence before a control can be created" do
    with_source do |item, _source, _copier|
      Fence.with_item(item) do
        result = in_another_session do
          Copier.new(provider_key: "up", legacy_item_id: item.id).run_quiesced
          :unexpected_copy
        rescue Fence::Busy
          :busy
        end
        assert_equal :busy, result
        assert_nil ProviderMigrationControl.find_by(legacy_type: "UpItem", legacy_id: item.id)
      end
    end
  end

  test "each bounded pass holds the exclusive session fence and stays paused between calls" do
    with_source do |item, source, copier|
      item.up_accounts.create!(account_id: "second-source", name: "Second", currency: "USD")
      selected = item.up_accounts.order(:id).first
      extract = copier.manifest.method(:extract_account)
      observed_manifest = copier.manifest.dup
      admissions = []
      # Observe the public writer boundary while the copier reads a source row.
      probe = -> do
        result = in_another_session do
          Fence.with_item(item) { :unexpected_write }
        rescue Fence::Busy
          :busy
        end
        admissions << result
      end
      observed_manifest.define_singleton_method(:extract_account) do |record|
        probe.call
        extract.call(record)
      end
      copier.stubs(:manifest).returns(observed_manifest)

      first = copier.run_quiesced.reload

      assert_equal [ :busy ], admissions
      assert_equal 1, first.provider_connection.external_accounts.count
      assert_equal selected.id, first.provider_migration_mappings.find_by!(role: "external_account").legacy_id
      assert_equal "copy", first.high_water_mark.fetch("phase")
      assert_nil first.lease_owner
      assert_raises(Fence::OwnershipChanged) { Fence.with_item(item) { flunk } }
      assert_equal 2, finish_quiesced(item).audit_results.fetch("source_account_count")
      assert UpAccount.exists?(source.id)
    end
  end

  test "ordinary copy cannot reclaim quiescing ownership or rewrite a completed audit" do
    with_source do |item, _source, copier|
      copier.run_quiesced
      verified = finish_quiesced(item)
      audit = verified.audit_results
      watermark = verified.high_water_mark

      assert_raises(Copier::Conflict) { copier.run }

      assert verified.reload.quiescing?
      assert_equal audit, verified.audit_results
      assert_equal watermark, verified.high_water_mark
      assert_nil verified.lease_owner
      assert_equal audit, copier.run_quiesced.reload.audit_results
    end
  end

  test "a failed final copy remains paused and can resume from its last committed account" do
    with_source do |item, source, copier|
      Provider::AccountData::MigrationManifest.any_instance.expects(:extract_account).raises(IOError, "Interrupted copy")
      DebugLogEntry.expects(:capture).with do |attributes|
        attributes[:category] == "provider_migration_error" && attributes[:provider_key] == "up" &&
          attributes[:family_id] == item.family_id && attributes.dig(:metadata, :error_class) == "IOError" &&
          attributes.dig(:metadata, :copy_mode) == "quiesced" && !attributes.to_json.include?("Interrupted copy")
      end

      assert_raises(IOError) { copier.run_quiesced }

      control = copier.control.reload
      assert control.quiescing?
      assert control.provider_connection.disabled?
      assert_equal "copy_failed", control.error_code
      assert_empty control.audit_results
      assert_nil control.lease_owner
      assert_raises(Fence::OwnershipChanged) { Fence.with_item(item) { flunk } }
      Provider::AccountData::MigrationManifest.any_instance.unstub(:extract_account)
      verified = finish_quiesced(item)
      assert_equal 1, verified.audit_results.fetch("source_account_count")
      assert_equal source.id, verified.provider_migration_mappings.find_by!(role: "external_account").legacy_id
    end
  end

  test "an explicit fresh comparison invalidates a completed pass without reopening legacy writes" do
    with_source do |item, source, copier|
      copier.run_quiesced
      verified = finish_quiesced(item)
      previous_run = verified.high_water_mark.fetch("copy_run_id")
      source.update_columns(current_balance: 17)

      restarted = copier.run_quiesced(restart: true).reload

      assert restarted.quiescing?
      assert_empty restarted.audit_results
      assert_not_equal previous_run, restarted.high_water_mark.fetch("copy_run_id")
      assert_equal "verify", restarted.high_water_mark.fetch("phase")
      assert_raises(Fence::OwnershipChanged) { Fence.with_item(item) { flunk } }
      assert_equal 17, finish_quiesced(item).provider_connection.external_accounts.sole.current_balance
    end
  end

  test "source changes reset the comparison without reopening legacy publication" do
    with_source do |item, source, copier|
      copier.run_quiesced
      # Deliberately simulate an uncovered writer. The final-copy audit does not
      # claim that the existing advisory boundary protects arbitrary SQL.
      source.update_columns(current_balance: 99)

      assert_raises(Copier::SourceChanged) { copier.run_quiesced }

      assert copier.control.reload.quiescing?
      assert_equal "copy", copier.control.high_water_mark.fetch("phase")
      assert_empty copier.control.audit_results
      assert_raises(Fence::OwnershipChanged) { Fence.with_item(item) { flunk } }
      assert_equal 99, finish_quiesced(item).provider_connection.external_accounts.sole.current_balance
    end
  end

  test "a live copy lease cannot be stolen and an expired lease starts a new final pass" do
    with_source do |item, _source, copier|
      copier.run
      control = copier.control.reload
      control.update!(lease_owner: "another-copy-worker", lease_expires_at: 2.minutes.from_now)
      before = control.attributes

      assert_raises(Copier::Busy) { copier.run_quiesced }
      assert_equal before, control.reload.attributes

      travel 3.minutes do
        copier.run_quiesced
        assert control.reload.quiescing?
        assert_equal "quiesced", control.high_water_mark.fetch("mode")
        assert_nil control.lease_owner
      end
      assert_raises(Fence::OwnershipChanged) { Fence.with_item(item) { flunk } }
    end
  end

  test "abandoning preparation restores legacy admission and invalidates the final audit" do
    with_source do |item, source, copier|
      link = AccountProvider.create!(account: accounts(:depository), provider: source)
      copier.run_quiesced
      finish_quiesced(item)
      external_id = link.reload.external_account_id

      resumed = copier.resume_legacy!

      assert resumed.legacy?
      assert_empty resumed.high_water_mark
      assert_empty resumed.audit_results
      assert resumed.provider_connection.disabled?
      assert_equal external_id, link.reload.external_account_id
      assert_equal source, link.effective_provider
      Fence.with_item(item) { |current| current.update!(access_token: "new-legacy-token") }
      assert_equal "new-legacy-token", item.reload.access_token
      assert_equal "test-final-copy-token", resumed.provider_connection.credentials.fetch("access_token")
      assert_nil copier.run_quiesced.reload.audit_results["verified_at"]
    end
  end

  test "native use indicators prevent both preparation resumption and return to legacy" do
    changes = {
      "control epoch" => ->(control, _connection) { control.update!(writer_epoch: 1) },
      "connection epoch" => ->(_control, connection) { connection.update!(writer_epoch: 1) },
      "enabled connection" => ->(_control, connection) { connection.update!(status: "good") },
      "writer lease" => ->(_control, connection) { connection.update!(lease_owner: "native", lease_expires_at: 1.minute.ago) },
      "refresh intent" => ->(_control, connection) { connection.update!(credential_state: { "status" => "uncertain" }) },
      "queued native job" => ->(_control, connection) { connection.syncs.create! },
      "native nonce" => ->(_control, connection) { connection.provider_sync_checkpoints.create!(stream: "request_nonce", scope_key: "connection", state: { "last_nonce" => "100" }) }
    }
    changes.each do |label, change|
      with_source do |item, _source, copier|
        copier.run_quiesced
        control = copier.control.reload
        change.call(control, control.provider_connection)
        before = control.reload.attributes

        assert_raises(Copier::Conflict, label) { copier.run_quiesced }
        assert_raises(Copier::Conflict, label) { copier.resume_legacy! }

        assert_equal before, control.reload.attributes, label
        assert_raises(Fence::OwnershipChanged, label) { Fence.with_item(item) { flunk } }
      end
    end
  end

  test "another quiescence protocol cannot be adopted or abandoned" do
    with_source do |item, _source, copier|
      control = ProviderMigrationControl.create!(family: item.family, provider_key: "up",
        legacy_type: "UpItem", legacy_id: item.id, state: "quiescing", high_water_mark: { "phase" => "other-work" })
      before = control.attributes

      assert_raises(Copier::Conflict) { copier.run_quiesced }
      assert_raises(Copier::Conflict) { copier.resume_legacy! }
      assert_equal before, control.reload.attributes
    end
  end

  private
    def with_source
      with_provider_encryption do
        DebugLogEntry.stubs(:capture)
        item = UpItem.create!(family: families(:dylan_family), name: "Final copy test", access_token: "test-final-copy-token")
        source = item.up_accounts.create!(account_id: SecureRandom.uuid, name: "Checking", currency: "USD", current_balance: 1)
        copier = Copier.new(provider_key: "up", legacy_item_id: item.id, batch_size: 1)
        begin
          yield item, source, copier
        ensure
          control = ProviderMigrationControl.find_by(legacy_type: "UpItem", legacy_id: item.id)
          connection_id = control&.provider_connection_id
          AccountProvider.where(provider_type: "UpAccount", provider_id: item.up_accounts.select(:id)).delete_all
          if connection_id
            ProviderSyncCheckpoint.where(provider_connection_id: connection_id).delete_all
            ProviderMigrationAccountBinding.where(family_id: control.family_id,
              provider_migration_mapping_id: control.provider_migration_mappings.select(:id)).delete_all
            IngestionBatch.where(provider_connection_id: connection_id).delete_all
          end
          if control
            control.provider_migration_mappings.delete_all
            control.delete
          end
          ProviderConnection.find_by(id: connection_id)&.destroy!
          item.reload.destroy!
        end
      end
    end

    def finish_quiesced(item)
      15.times do
        control = Copier.new(provider_key: "up", legacy_item_id: item.id, batch_size: 1).run_quiesced.reload
        return control if control.high_water_mark["phase"] == "verified"
      end
      flunk "Final copy did not finish within the expected bounded calls"
    end

    def in_another_session(&block)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      worker = Thread.new { ApplicationRecord.connection_pool.with_connection(&block) }
      Timeout.timeout(5) { worker.value }
    ensure
      worker&.kill if worker&.alive?
      worker&.join
    end
end
