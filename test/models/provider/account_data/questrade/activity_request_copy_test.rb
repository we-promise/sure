require "test_helper"
require_relative "../../../../support/identity_bootstrap_test_helper"

class Provider::AccountData::Questrade::ActivityRequestCopyTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  Copier = Provider::AccountData::MigrationCopier
  Manifest = Provider::AccountData::MigrationManifest
  Value = Provider::AccountData::MigrationValue
  Request = QuestradeAccount::ActivitiesRequest
  Fence = Provider::AccountData::LegacyWriterFence
  REQUEST_COLUMNS = %w[activities_fetch_request activities_fetch_revision activities_fetch_due_at].freeze

  # Fixture-only description of the schema before the durable request columns.
  # The production serializer, HMAC, encryption, archive reader and verifier
  # remain real; this is not a production archive conversion/recovery API.
  class HistoricalManifest < Provider::AccountData::MigrationManifest
    def dispositions(kind)
      values = super
      return values unless kind == :account
      values.transform_values { |columns| columns - REQUEST_COLUMNS }
    end
  end

  setup do
    DebugLogEntry.stubs(:capture)
    Provider::Questrade.expects(:new).never
    clear_enqueued_jobs
  end
  teardown { clear_enqueued_jobs }

  test "a completed request and its typed checkpoint fields copy losslessly under real quiescence" do
    with_source do |context, sync|
      Request.enqueue(context.source, start_date: Date.current - 3, sync: sync)
      original = Request.read(context.source.reload)
      Request.with_claim(context.source, request_id: original.fetch("id"), revision: context.source.activities_fetch_revision) do |_session, request|
        request.complete!(context.source)
      end
      receipt = Request.read(context.source.reload)
      assert_equal "completed", receipt.fetch("state")
      assert_equal 3, context.source.activities_fetch_revision
      assert_nil context.source.activities_fetch_due_at
      assert context.source.last_activities_sync

      copied = copy(context)
      assert_lossless_request(copied, receipt)
      before = retained_state(copied)
      assert retained_page(copied).complete
      assert_equal before, retained_state(copied)
      assert copied.control.quiescing?
      assert copied.external.provider_connection.disabled?
    end
  end

  test "explicitly disposed historical work remains unknown in the copied receipt" do
    with_source do |context, _sync|
      context.source.update!(activities_fetch_pending: true)
      Request.dispose_unowned!(context.source, family: context.family)
      receipt = Request.read(context.source.reload)
      assert_equal "legacy_unowned", receipt.fetch("origin")
      assert_equal "cancelled", receipt.fetch("state")
      assert_nil receipt.fetch("start_date")
      assert_nil receipt.fetch("end_date")
      assert_nil context.source.last_activities_sync

      copied = copy(context)
      assert_lossless_request(copied, receipt)
      assert retained_page(copied).complete
      assert_nil copied.source.reload.last_activities_sync
      assert_empty copied.account.entries
    end
  end

  test "shadow copy retains a queued request due timestamp but cannot claim quiesced readiness" do
    with_source do |context, sync|
      Request.enqueue(context.source, start_date: Date.current, sync: sync)
      receipt = Request.read(context.source.reload)
      due_at = context.source.activities_fetch_due_at
      assert due_at
      copied = copy(context, quiesced: false)
      assert_lossless_request(copied, receipt)
      assert_equal due_at, copied.copier.snapshot_for(copied.mapping).fetch("attributes").fetch("activities_fetch_due_at")
      assert copied.control.shadow?
      before = retained_state(copied)
      assert_raises(Fence::OwnershipChanged) { copied.copier.run_quiesced }
      assert_equal before, retained_state(copied)
      assert copied.external.provider_connection.disabled?
    end
  end

  test "an authenticated old archive missing all request columns refuses retained verification without rewriting evidence" do
    with_source do |context, _sync|
      context.source.update!(activities_fetch_pending: true)
      Request.dispose_unowned!(context.source, family: context.family)
      copied = copy(context)
      current_checksum = copied.mapping.source_checksum
      current_archive = copied.copier.snapshot_for(copied.mapping)
      original_batches = batch_storage(copied)

      capture_historical_archive(copied)

      old_archive = copied.copier.snapshot_for(copied.mapping.reload)
      assert_not_equal current_checksum, copied.mapping.source_checksum
      REQUEST_COLUMNS.each do |column|
        assert_not old_archive.fetch("attributes").key?(column)
        assert_not old_archive.fetch("columns").key?(column)
        assert_not_includes old_archive.fetch("dispositions").values.flatten, column
      end
      assert_equal current_archive.fetch("account_binding"), old_archive.fetch("account_binding")
      assert_equal current_archive, copied.copier.snapshot_for(copied.mapping, source_checksum: current_checksum)
      assert Provider::AccountData::RetainedAccountIndex.assert_complete_for!(copied.control)
      before = retained_state(copied)

      error = assert_raises(Copier::SourceChanged) { retained_page(copied) }

      assert_match(/source row changed/i, error.message)
      assert_equal before, retained_state(copied)
      assert_equal old_archive, copied.copier.snapshot_for(copied.mapping.reload)
      original_batches.each { |id, stored| assert_equal stored, batch_storage(copied).fetch(id) }
      assert copied.control.reload.quiescing?
      assert copied.external.provider_connection.disabled?
    end
  end

  private
    def with_source
      with_provider_encryption do
        family = Family.create!(name: "Questrade receipt copy")
        item = family.questrade_items.create!(name: "Questrade", refresh_token: "private-original-token")
        account = family.accounts.create!(name: "Original brokerage", currency: "CAD", balance: 123.45, accountable: Investment.new)
        begin
          source = item.questrade_accounts.create!(name: "Brokerage", currency: "CAD", questrade_account_id: "123",
            raw_activities_payload: [], current_balance: BigDecimal("123.45"))
          link = AccountProvider.create!(account: account, provider: source)
          copier = Copier.new(provider_key: "questrade", legacy_item_id: item.id, batch_size: 1, chunk_bytes: 1024)
          context = IdentityBootstrapTestHelper::Context.new(family: family, item: item, source: source, account: account,
            link: link, copier: copier, control: nil, mapping: nil, external: nil)
          yield context, item.syncs.create!
        ensure
          Sync.where(syncable_type: "QuestradeItem", syncable_id: item.id).delete_all
          cleanup_identity_source(item, account)
          Sync.where(syncable_type: "Family", syncable_id: family.id).delete_all
          family.destroy!
        end
      end
    end

    def copy(context, quiesced: true)
      financial = identity_financial_snapshot(context)
      source = context.source.reload.attributes
      control = nil
      20.times do
        control = (quiesced ? context.copier.run_quiesced : context.copier.run).reload
        break if quiesced ? control.high_water_mark["phase"] == "verified" : control.shadow?
      end
      assert(quiesced ? control.high_water_mark["phase"] == "verified" : control.shadow?)
      assert_equal financial, identity_financial_snapshot(context)
      assert_equal source, context.source.reload.attributes
      mapping = control.provider_migration_mappings.find_by!(role: "external_account", legacy_id: context.source.id)
      IdentityBootstrapTestHelper::Context.new(**context.to_h.merge(control: control, mapping: mapping, external: mapping.external_account))
    end

    def assert_lossless_request(context, receipt)
      archive = context.copier.snapshot_for(context.mapping)
      projection = context.copier.manifest.extract_account(context.source.reload)
      assert_equal projection.source_attributes, archive.fetch("attributes")
      assert_equal receipt, archive.fetch("attributes").fetch("activities_fetch_request")
      assert_equal "jsonb", archive.fetch("columns").fetch("activities_fetch_request").fetch("type")
      # PostgreSQL bigint is exposed as the Rails integer type (with 8-byte
      # storage); retain the adapter's real column description, not a guess.
      assert_equal QuestradeAccount.columns_hash.fetch("activities_fetch_revision").type.to_s,
        archive.fetch("columns").fetch("activities_fetch_revision").fetch("type")
      assert_kind_of Integer, archive.fetch("attributes").fetch("activities_fetch_revision")
      assert_equal "datetime", archive.fetch("columns").fetch("activities_fetch_due_at").fetch("type")
      checkpoint = context.external.provider_sync_checkpoints.find_by!(stream: "legacy_state", scope_key: "QuestradeAccount:#{context.source.id}")
      assert_equal projection.checkpoints, Value.decode(checkpoint.state.fetch("columns"))
      assert_nil checkpoint.covered_through
      assert_nil checkpoint.ingestion_batch_id
      context.external.provider_connection.ingestion_batches.where(external_account: context.external).each do |batch|
        assert_provider_column_encrypted(batch, :payload, Request::FORMAT)
      end
    end

    def capture_historical_archive(context)
      current = context.copier.manifest
      original = context.copier.snapshot_for(context.mapping)
      projection = current.extract_account(context.source.reload)
      historical = Manifest::Projection.new(provider_key: projection.provider_key, kind: projection.kind,
        source_table: projection.source_table, source_type: projection.source_type,
        buckets: projection.buckets.transform_values { |values| values.except(*REQUEST_COLUMNS) },
        column_metadata: projection.column_metadata.except(*REQUEST_COLUMNS), external_id: projection.external_id,
        identity_components: projection.identity_components)
      # Use the existing fixture seam for genuine encrypted archive versions.
      # No original chunk, checksum or reverse-index receipt is overwritten.
      Fence.with_exclusive(context.item) do
        context.control.with_lock do
          context.copier.instance_variable_set(:@manifest, HistoricalManifest.new("questrade"))
          binding = original.fetch("account_binding")
          context.copier.send(:save_mapping!, context.mapping, context.external, historical, account_binding: binding)
          context.copier.send(:capture_snapshot!, context.mapping, historical, account_binding: binding)
          context.mapping.update!(verified_at: Time.current)
          Provider::AccountData::RetainedAccountIndex.capture!(mapping: context.mapping)
        end
      end
    ensure
      context.copier.instance_variable_set(:@manifest, current)
    end

    def retained_page(context)
      Copier.new(provider_key: "questrade", legacy_item_id: context.item.id)
        .verify_retained_quiesced_page(family: context.family, limit: 1)
    end

    def batch_storage(context)
      context.external.provider_connection.ingestion_batches.order(:id).to_h do |batch|
        [ batch.id, [ batch.attributes, batch.read_attribute_before_type_cast("payload") ] ]
      end
    end

    def retained_state(context)
      { financial: identity_financial_snapshot(context), source: context.source.reload.attributes,
        control: context.control.reload.attributes, connection: context.external.provider_connection.reload.attributes,
        mappings: context.control.provider_migration_mappings.order(:id).map(&:attributes), batches: batch_storage(context),
        checkpoints: context.external.provider_connection.provider_sync_checkpoints.order(:id).map(&:attributes),
        receipts: ProviderMigrationAccountBinding.where(provider_migration_mapping_id: context.mapping.id).order(:id).map(&:attributes) }
    end
end
