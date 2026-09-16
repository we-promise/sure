require "test_helper"
require_relative "../../../support/identity_bootstrap_test_helper"

class Provider::AccountData::CopiedAccountBindingTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  self.use_transactional_tests = false

  Copier = Provider::AccountData::MigrationCopier
  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    DebugLogEntry.stubs(:capture)
  end

  test "every copied account retains its final shared link and non-economic financial context" do
    %w[up plaid].each do |provider_key|
      with_identity_source(provider_key: provider_key) do |context|
        archive = context.copier.snapshot_for(context.mapping)
        binding = archive.fetch("account_binding")

        assert_equal Copier::ACCOUNT_BINDING_FORMAT, binding.fetch("format")
        assert_equal context.link.reload.attributes.slice(*Copier::RETAINED_LINK_COLUMNS), binding.fetch("link")
        assert_equal context.account.reload.attributes.slice(*Copier::RETAINED_FINANCIAL_CONTEXT_COLUMNS), binding.fetch("financial_context")
        assert_equal context.external.id, binding.fetch("link").fetch("external_account_id")
        assert_equal context.link.lock_version, binding.fetch("link").fetch("lock_version")
        assert_equal context.copier.manifest.extract_account(context.source.reload).source_attributes, archive.fetch("attributes")
        refute binding.fetch("financial_context").key?("balance")
        refute binding.fetch("financial_context").key?("cash_balance")
        queries = capture_sql_queries do
          assert Copier.verify_account_binding!(archive: archive, link: context.link, financial: context.account)
        end
        assert_empty queries, "Already loaded account binding verification must be pure"
      end
    end
  end

  test "same-family relinking after copy cannot be accepted by a fresh retained verifier" do
    %w[up plaid].each do |provider_key|
      with_identity_source(provider_key: provider_key) do |context|
        with_other_account(context) do |other|
          original = context.copier.snapshot_for(context.mapping)
          Account::SourcePolicy.where(account_provider_id: context.link.id).delete_all
          context.link.update!(account: other)
          before = storage(context)

          error = assert_raises(Copier::Conflict) { retained_page(context) }

          assert_match(/copy-time account binding changed/i, error.message)
          assert_equal before, storage(context)
          assert_equal original, context.copier.snapshot_for(context.mapping)
          assert_equal other.id, context.link.reload.account_id
          assert context.control.reload.quiescing?
          assert context.control.provider_connection.disabled?
        end
      end
    end
  end

  test "removing or recreating a join cannot replace the original copied link identity" do
    [ false, true ].each do |recreate|
      with_identity_source do |context|
        original_link_id = context.link.id
        Account::SourcePolicy.where(account_provider_id: original_link_id).delete_all
        context.link.delete
        replacement = AccountProvider.create!(account: context.account, provider: context.source, external_account: context.external) if recreate
        before = storage(context)

        assert_raises(Copier::Conflict) { retained_page(context) }

        assert_equal before, storage(context)
        assert_not_equal original_link_id, replacement.id if replacement
      end
    end
  end

  test "an explicitly unlinked copied source cannot gain financial ownership between reads" do
    with_identity_source do |context|
      source = context.item.up_accounts.create!(account_id: SecureRandom.uuid, name: "Unlinked source", currency: "USD")
      finish_copy(context, restart: true)
      mapping = context.control.provider_migration_mappings.find_by!(legacy_id: source.id, role: "external_account")
      archive = context.copier.snapshot_for(mapping)
      assert_equal({ "format" => Copier::ACCOUNT_BINDING_FORMAT, "link" => nil, "financial_context" => nil }, archive.fetch("account_binding"))
      assert Copier.verify_account_binding!(archive: archive, link: nil, financial: nil)
      assert retained_page(context).complete
      with_other_account(context) do |other|
        new_link = AccountProvider.create!(account: other, provider: source, external_account: mapping.external_account)
        before = storage(context)

        assert_raises(Copier::Conflict) { retained_page(context) }

        assert_equal before, storage(context)
        assert_equal archive, context.copier.snapshot_for(mapping)
        new_link.delete
      end
    end
  end

  test "economic edits preserve the copied binding while currency delegated identity and link revision changes reject" do
    with_identity_source do |context|
      archive = context.copier.snapshot_for(context.mapping)
      context.account.update!(name: "My account", balance: BigDecimal("42"), cash_balance: BigDecimal("7"))

      assert retained_page(context).complete
      assert_equal archive, context.copier.snapshot_for(context.mapping)
      context.link.touch
      assert_raises(Copier::Conflict) { retained_page(context) }
    end
    [ :currency, :accountable_id ].each do |attribute|
      with_identity_source do |context|
        original = context.account.read_attribute(attribute)
        begin
          context.account.update_columns(attribute => (attribute == :currency ? "EUR" : SecureRandom.uuid))
          before = storage(context)

          assert_raises(Copier::Conflict) { retained_page(context) }

          assert_equal before, storage(context)
        ensure
          context.account.update_columns(attribute => original)
        end
      end
    end
  end

  test "ordinary copy verification also rejects a relink after its account copy transaction committed" do
    with_identity_source(quiesced: false) do |context|
      context.copier.run_quiesced
      assert_equal "verify", context.control.reload.high_water_mark.fetch("phase")
      archived = context.copier.snapshot_for(context.mapping.reload)
      with_other_account(context) do |other|
        Account::SourcePolicy.where(account_provider_id: context.link.id).delete_all
        context.link.update!(account: other)

        error = assert_raises(Copier::Conflict) { context.copier.run_quiesced }

        assert_match(/copy-time account binding changed/i, error.message)
        assert_equal archived, context.copier.snapshot_for(context.mapping.reload)
        assert_nil context.mapping.verified_at
        assert context.control.reload.quiescing?
        assert context.control.provider_connection.disabled?
      end
    end
  end

  test "recopy preserves older source-only archives and cannot claim complete historical ownership" do
    with_identity_source do |context|
      make_source_only_archive(context)
      old_checksum = context.mapping.source_checksum
      old_archive = context.copier.snapshot_for(context.mapping)
      assert_not old_archive.key?("account_binding")
      old_batches = context.control.provider_connection.ingestion_batches.order(:id).to_h { |batch| [ batch.id, batch.attributes ] }
      before = storage(context)

      error = assert_raises(Copier::Conflict) { retained_page(context) }

      assert_match(/require reverse indexing/i, error.message)
      assert_equal before, storage(context)
      assert_raises(Copier::Conflict) { finish_copy(context, restart: true) }
      assert_not_equal old_checksum, context.mapping.reload.source_checksum
      fresh = context.copier.snapshot_for(context.mapping)
      assert_equal old_archive.fetch("attributes"), fresh.fetch("attributes")
      assert_equal context.link.id, fresh.fetch("account_binding").fetch("link").fetch("id")
      old_batches.each { |id, attributes| assert_equal attributes, IngestionBatch.find(id).attributes }
      index = Provider::AccountData::RetainedAccountIndex
      assert_equal context.account.id, index.verify!(mapping: context.mapping).financial_account_id
      assert_raises(Copier::Conflict) { index.capture!(mapping: context.mapping, source_checksum: old_checksum) }
      assert_raises(Copier::Conflict) { index.assert_complete_for!(context.control) }
      assert context.control.reload.quiescing?
      assert context.control.provider_connection.disabled?
    end
  end

  test "a resumed ordinary verification cannot infer the missing binding of an older archive" do
    with_identity_source do |context|
      make_source_only_archive(context)
      context.control.update!(high_water_mark: context.control.high_water_mark.merge("phase" => "verify"))
      old_archive = context.copier.snapshot_for(context.mapping)

      error = assert_raises(Copier::Conflict) { context.copier.run_quiesced }

      assert_match(/lacks a verified copy-time account binding/i, error.message)
      assert_equal old_archive, context.copier.snapshot_for(context.mapping)
      assert context.control.reload.quiescing?
      assert context.control.provider_connection.disabled?
    end
  end

  test "an eligible fresh copy captures a changed binding under a new checksum without rewriting old chunks" do
    with_identity_source do |context|
      original_archive = context.copier.snapshot_for(context.mapping)
      original_checksum = context.mapping.source_checksum
      original_batches = context.control.provider_connection.ingestion_batches.order(:id).to_h { |batch| [ batch.id, batch.attributes ] }
      with_other_account(context) do |other|
        Account::SourcePolicy.where(account_provider_id: context.link.id).delete_all
        context.link.update!(account: other)

        finish_copy(context, restart: true)

        assert_not_equal original_checksum, context.mapping.reload.source_checksum
        fresh = context.copier.snapshot_for(context.mapping)
        assert_equal original_archive.fetch("attributes"), fresh.fetch("attributes")
        assert_equal context.account.id, original_archive.fetch("account_binding").fetch("financial_context").fetch("id")
        assert_equal other.id, fresh.fetch("account_binding").fetch("financial_context").fetch("id")
        original_batches.each { |id, attributes| assert_equal attributes, IngestionBatch.find(id).attributes }
        assert retained_page(context).complete
      end
    end
  end

  private
    def retained_page(context)
      Copier.new(provider_key: context.control.provider_key, legacy_item_id: context.item.id)
        .verify_retained_quiesced_page(family: context.family)
    end

    def finish_copy(context, restart: false)
      20.times do |index|
        context.copier.run_quiesced(restart: restart && index.zero?)
        return if context.control.reload.high_water_mark["phase"] == "verified"
      end
      flunk "Account binding copy did not finish within its bounded pages"
    end

    def with_other_account(context)
      other = context.family.accounts.create!(name: "Another financial account", currency: "USD", balance: BigDecimal("0"),
        accountable: Depository.new, status: "active")
      yield other
    ensure
      if other
        Account::SourcePolicy.where(account_id: other.id).delete_all
        retained = AccountProvider.find_by(id: context.link.id)
        retained.update!(account: context.account) if retained&.account_id == other.id
        AccountProvider.where(account_id: other.id).delete_all
        other.reload.destroy!
      end
    end

    def make_source_only_archive(context)
      # Exercise the authentic old writer format, not a checksum bypass or a
      # fabricated plaintext archive. Such an archive remains readable only.
      Fence.with_exclusive(context.item) do
        context.control.with_lock do
          projection = context.copier.manifest.extract_account(context.source.reload)
          context.copier.send(:save_mapping!, context.mapping, context.external, projection)
          context.copier.send(:capture_snapshot!, context.mapping, projection)
          context.mapping.update!(verified_at: Time.current)
        end
      end
    end

    def storage(context)
      connection = context.control.reload.provider_connection
      { "account" => context.account.reload.attributes, "source" => context.source.reload.attributes,
        "links" => AccountProvider.where(external_account_id: connection.external_accounts.select(:id)).order(:id).map(&:attributes),
        "control" => context.control.attributes, "connection" => connection.attributes,
        "mappings" => context.control.provider_migration_mappings.order(:id).map(&:attributes),
        "batches" => connection.ingestion_batches.order(:id).map(&:attributes),
        "external_accounts" => connection.external_accounts.order(:id).map(&:attributes) }
    end
end
