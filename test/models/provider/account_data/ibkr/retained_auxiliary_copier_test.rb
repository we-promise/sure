require "test_helper"
require "stringio"
require_relative "../../../../support/identity_bootstrap_test_helper"

class Provider::AccountData::Ibkr::RetainedAuxiliaryCopierTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  self.use_transactional_tests = false

  Copier = Provider::AccountData::Ibkr::AuxiliaryCopier

  setup do
    DebugLogEntry.stubs(:capture)
  end

  test "retained copy resumes its original layout and returns immutable copy-bound receipts" do
    with_retained_logo do
      original = [ @control.reload.attributes, @item.reload.attributes, @source.reload.attributes, @account.reload.attributes, @blob.reload.attributes ]
      first = copier.run_retained(family: @family)
      assert_instance_of Copier, Provider::AccountData::AuxiliaryCopier.for(control: @control)
      assert_equal "ibkr-retained-auxiliary/v1", first.context.fetch("format")
      assert_equal "ibkr-logo-auxiliary/v1", checkpoint.state.fetch("format")
      assert_equal "IbkrItem:#{@item.id}:logo", checkpoint.scope_key
      assert archive_batches.sole.idempotency_key.start_with?("ibkr-auxiliary:#{@control.id}:")
      manifest = Provider::AccountData::MigrationValue.decode(checkpoint.state.fetch("manifest"))
      legacy_key = Rails.application.key_generator.generate_key("ibkr-auxiliary-manifest-v1", 32)
      assert_equal OpenSSL::HMAC.hexdigest("SHA256", legacy_key, Provider::AccountData::MigrationValue.dump(manifest)), first.context.fetch("source_digest")
      assert_equal "copy", first.phase
      assert_equal 1, first.copied_chunks
      assert_equal @control.high_water_mark.fetch("copy_run_id"), first.context.fetch("copy").fetch("copy_run_id")
      assert first.context.frozen?
      assert first.context.fetch("copy").frozen?

      # New workers honor the original layout, even with another constructor size.
      resumed = Copier.new(control: @control, chunks_per_run: 1)
      final = finish_retained(resumed, expected_context: first.context)

      assert final.complete?
      assert_equal first.context, final.context
      assert_equal first.checkpoint_id, final.checkpoint_id
      assert_equal 3, final.verified_chunks
      assert_equal @bytes, resumed.each_archived_chunk.to_a.join.b
      assert_equal original, [ @control.reload.attributes, @item.reload.attributes, @source.reload.attributes, @account.reload.attributes, @blob.reload.attributes ]
      assert_equal @blob.id, @connection.reload.logo_attachment.blob_id
      before = checkpoint.attributes
      assert finish_retained(resumed, expected_context: first.context).complete?
      assert_equal before, checkpoint.reload.attributes
      assert_raises(Copier::Conflict) { resumed.run }
      assert_raises(Copier::Conflict) { resumed.restart_verification! }
    end
  end

  test "completed auxiliary evidence is reverified in read-only pages after financial identities exist" do
    with_retained_logo do
      finished = finish_retained
      publish_identities
      original = snapshot
      first = copier.verify_retained_page(family: @family, limit: 1)
      refute first.complete
      assert_equal [ 0 ], first.rows.map { |row| row.fetch("index") }
      assert_equal 1024, first.rows.sole.fetch("byte_size")
      assert_equal finished.context, first.context.except("content_sha256", "target_attachment", "limit")
      assert first.next_cursor.frozen?

      second = copier.verify_retained_page(family: @family, cursor: first.next_cursor, limit: 1)
      last = copier.verify_retained_page(family: @family, cursor: second.next_cursor, limit: 1)

      assert_equal [ 1 ], second.rows.map { |row| row.fetch("index") }
      assert_equal [ 2 ], last.rows.map { |row| row.fetch("index") }
      assert last.complete
      assert_nil last.next_cursor
      assert_equal original, snapshot
    end
  end

  test "storage interruption retries the same read-only page outside a database transaction" do
    with_retained_logo do
      finish_retained
      original = snapshot
      first = copier.verify_retained_page(family: @family, limit: 1)
      ActiveStorage::Blob.any_instance.expects(:download_chunk).with(1024...2048).raises(IOError, "interrupted")
      assert_raises(IOError) { copier.verify_retained_page(family: @family, cursor: first.next_cursor, limit: 1) }
      ActiveStorage::Blob.any_instance.unstub(:download_chunk)
      ActiveStorage::Blob.any_instance.expects(:download_chunk).with do |range|
        assert_equal 0, ApplicationRecord.connection.open_transactions
        range == (1024...2048)
      end.returns(@bytes.byteslice(1024, 1024))

      retry_page = copier.verify_retained_page(family: @family, cursor: first.next_cursor, limit: 1)

      assert_equal [ 1 ], retry_page.rows.map { |row| row.fetch("index") }
      assert_equal original, snapshot
    end
  end

  test "an absent logo has an explicit completed retained receipt and an empty verification page" do
    with_retained_logo(bytes: nil) do
      ActiveStorage::Blob.any_instance.expects(:download_chunk).never
      result = finish_retained
      original = snapshot

      page = copier.verify_retained_page(family: @family, limit: 1)

      assert result.complete?
      assert page.complete
      assert_empty page.rows
      assert_equal 0, result.context.fetch("chunks")
      assert_nil Provider::AccountData::MigrationValue.decode(page.context.fetch("target_attachment"))
      assert_equal original, snapshot
    end
  end

  test "unbound receipts need explicit reconciliation and are never silently adopted" do
    with_retained_logo do
      ordinary = copier
      10.times { break if ordinary.run.state.fetch("phase") == "complete" }
      assert_equal "complete", checkpoint.state.fetch("phase")
      original = snapshot

      error = assert_raises(Copier::Conflict) { copier.run_retained(family: @family) }
      assert_includes error.message, "explicit reconciliation"
      assert_raises(Copier::Conflict) { copier.verify_retained_page(family: @family) }

      assert_equal original, snapshot
    end
  end

  test "retained chunks without their checkpoint cannot initialize a replacement" do
    with_retained_logo do
      first = copier.run_retained(family: @family)
      ProviderSyncCheckpoint.find(first.checkpoint_id).delete
      original = archive_batches.map(&:attributes)

      assert_raises(Copier::Conflict) { copier.run_retained(family: @family) }
      assert_raises(Copier::Conflict) { copier.run }

      assert_equal original, archive_batches.map(&:attributes)
      assert_nil @connection.provider_sync_checkpoints.find_by(stream: Copier::STREAM)
    end
  end

  test "new auxiliary capture is refused after financial identity publication" do
    with_retained_logo do
      publish_identities
      ActiveStorage::Blob.any_instance.expects(:download_chunk).never
      original = snapshot

      assert_raises(Copier::Conflict) { copier.run_retained(family: @family) }

      assert_equal original, snapshot
      assert_empty archive_batches
    end
  end

  test "family copy-run and page-size drift refuse continuation without modifying original receipts" do
    with_retained_logo do
      finished = finish_retained
      page = copier.verify_retained_page(family: @family, limit: 1)
      original = snapshot
      assert_raises(Copier::Conflict) { copier.verify_retained_page(family: families(:empty), cursor: page.next_cursor, limit: 1) }
      assert_raises(Copier::Conflict) { copier.verify_retained_page(family: @family, cursor: page.next_cursor, limit: 2) }
      bad = finished.context.deep_dup
      bad.fetch("copy")["copy_run_id"] = SecureRandom.uuid
      assert_raises(Copier::Conflict) { copier.run_retained(family: @family, expected_context: bad) }
      assert_equal original, snapshot

      @control.update!(high_water_mark: @control.high_water_mark.merge("copy_run_id" => SecureRandom.uuid))
      assert_raises(Provider::AccountData::MigrationCopier::Conflict) do
        copier.verify_retained_page(family: @family, cursor: page.next_cursor, limit: 1)
      end
      assert_equal original.fetch(:auxiliary), snapshot.fetch(:auxiliary)
      assert_equal original.fetch(:batches), snapshot.fetch(:batches)
    end
  end

  test "changed storage bytes or original target attachment metadata cannot pass verification" do
    with_retained_logo do
      finish_retained
      original = snapshot
      ActiveStorage::Blob.any_instance.expects(:download_chunk).with(0...1024).returns("x" * 1024)
      assert_raises(Copier::Conflict) { copier.verify_retained_page(family: @family, limit: 1) }
      ActiveStorage::Blob.any_instance.unstub(:download_chunk)
      assert_equal original, snapshot
      @connection.logo_attachment.update_columns(created_at: 1.day.ago)
      ActiveStorage::Blob.any_instance.expects(:download_chunk).never

      assert_raises(Copier::Conflict) { copier.verify_retained_page(family: @family, limit: 1) }

      assert_equal original.fetch(:auxiliary), snapshot.fetch(:auxiliary)
      assert_equal original.fetch(:batches), snapshot.fetch(:batches)
    end
  end

  test "retirement entrypoint keeps the original IBKR archive contract and refuses pre-native ownership" do
    with_retained_logo do
      finish_retained
      original = snapshot
      worker = Provider::AccountData::AuxiliaryCopier.for(control: @control)
      assert_instance_of Copier, worker
      ActiveStorage::Blob.any_instance.expects(:download_chunk).never
      Provider::AccountData::LegacyWriterFence.with_exclusive(@item) do
        assert_raises(Copier::Conflict) { worker.prepare_retirement(family: @family) }
      end
      assert_equal original, snapshot
      assert_equal @bytes, worker.each_archived_chunk.to_a.join.b
      assert_equal "ibkr-logo-auxiliary/v1", checkpoint.state.fetch("format")
      assert_equal "legacy_ibkr_auxiliary", checkpoint.stream
    end
  end

  private
    def with_retained_logo(bytes: ("\x00\xFFlogo-data".b * 250))
      with_provider_encryption do
        @bytes, @family = bytes, families(:dylan_family)
        @item = IbkrItem.create!(family: @family, name: "Retained IBKR logo", query_id: "query", token: "private-token")
        @account = @family.accounts.create!(name: "Retained IBKR account", currency: "USD", balance: 100, accountable: Investment.new)
        begin
          if bytes
            @blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: "retained-private-logo.png", content_type: "image/png", identify: false)
            @item.logo.attach(@blob)
          end
          @source = @item.ibkr_accounts.create!(name: "Investment", ibkr_account_id: "ibkr-retained", currency: "USD", current_balance: 100)
          @link = AccountProvider.create!(account: @account, provider: @source)
          @account.entries.create!(name: "Existing cash activity", external_id: "ibkr_cash_retained", source: "ibkr", currency: "USD",
            amount: 10, date: Date.current, entryable: Transaction.new)
          main = Provider::AccountData::MigrationCopier.new(provider_key: "ibkr", legacy_item_id: @item.id)
          15.times do
            @control = main.run_quiesced.reload
            break if @control.high_water_mark["phase"] == "verified"
          end
          assert_equal "verified", @control.high_water_mark["phase"]
          @connection = @control.provider_connection
          @mapping = @control.provider_migration_mappings.find_by!(role: "external_account", legacy_id: @source.id)
          Account::SourcePolicy.select!(account: @account, account_provider: @link.reload, resource: "activities")
          clear_enqueued_jobs
          yield
        ensure
          ActiveStorage::Attachment.where(record_type: "ProviderConnection", record_id: @connection.id).delete_all if @connection
          ActiveStorage::Attachment.where(record_type: "IbkrItem", record_id: @item.id).delete_all
          cleanup_identity_source(@item, @account)
          @blob&.purge
          clear_enqueued_jobs
        end
      end
    end

    def copier
      Copier.new(control: @control, chunks_per_run: 1, chunk_bytes: 1024)
    end

    def finish_retained(worker = copier, expected_context: nil)
      15.times do
        result = worker.run_retained(family: @family, expected_context: expected_context)
        expected_context ||= result.context
        return result if result.complete?
      end
      flunk "Retained auxiliary fixture did not complete"
    end

    def publish_identities
      publisher = Ingestion::IdentityBootstrap.new(mapping: @mapping, family: @family)
      result = nil
      10.times do
        result = publisher.run
        break if result.verified?
      end
      assert result.verified?
    end

    def checkpoint
      @connection.provider_sync_checkpoints.find_by!(stream: Copier::STREAM)
    end

    def archive_batches
      @connection.ingestion_batches.where(stream: Copier::STREAM).order(:sequence)
    end

    def snapshot
      { auxiliary: @connection.provider_sync_checkpoints.where(stream: Copier::STREAM).map(&:attributes),
        batches: archive_batches.map(&:attributes), control: @control.reload.attributes,
        entry_sources: EntrySource.where(account: @account).order(:id).map(&:attributes),
        entries: @account.entries.order(:id).map { |entry| [ entry.attributes, entry.entryable.attributes ] },
        attachments: ActiveStorage::Attachment.where(record_id: [ @item.id, @connection.id ]).order(:id).map(&:attributes) }
    end
end
