require "test_helper"
require_relative "../../support/identity_bootstrap_test_helper"

class Ingestion::PendingTransactionBootstrapPublicationTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  PROVIDERS = %w[akahu lunchflow redbark].freeze

  setup do
    # Publication is exercised locally; production readiness stays gated.
    PROVIDERS.each { |key| Provider::AccountData::Registry.declared_adapter(key).stubs(:native_ready?).returns(true) }
  end
  teardown { clear_enqueued_jobs }

  PROVIDERS.each do |key|
    test "#{key} settles a signed legacy pending identity and preserves its original proof on replay" do
      with_copied_pending(key) do |context, entry, pending_record|
        original_id = entry.id
        before_bootstrap = identity_financial_snapshot(context)
        result = nil
        assert_no_difference [ "Entry.count", "Transaction.count", "Sync.count" ] do
          5.times do
            result = Ingestion::IdentityBootstrap.new(mapping: context.mapping, family: context.family, page_size: 1).run
            break if result.verified?
          end
        end
        assert result.verified?
        assert_equal before_bootstrap, identity_financial_snapshot(context)

        pending = SourceRecord.find_by!(external_account: context.external, external_id: pending_record[:external_id])
        original_mapping = pending.entry_source.attributes
        bootstrap_batch = pending.ingestion_batch
        original_batch = bootstrap_batch.attributes
        original_ciphertext = bootstrap_batch.read_attribute_before_type_cast("payload")
        assert_equal "migration", bootstrap_batch.origin_kind
        assert_equal "current", pending.entry_source.bootstrap_identity_role
        assert_equal original_id, pending.entry_source.entry_identity
        assert pending.pending?

        posted = normalized_record(key, pending: false)
        posted_batch = capture_page(context, posted)
        assert_no_difference [ "Entry.count", "Transaction.count" ] do
          publish(context, posted_batch)
        end
        assert_equal original_id, context.account.entries.sole.id
        assert_equal posted[:external_id], entry.reload.external_id
        assert_equal pending_record[:date], entry.date
        assert_equal pending_record[:amount], entry.amount
        assert_equal "Retained user description", entry.name
        assert_equal "Retained user notes", entry.notes
        assert entry.locked?(:name)
        assert entry.locked?(:date)
        assert_not entry.transaction.pending?
        assert_equal [ pending_record[:external_id] ], entry.transaction.extra.fetch("auto_claimed_pending_ids")
        current = SourceRecord.find_by!(external_account: context.external, external_id: posted[:external_id])
        assert_equal original_id, current.entry_source.entry_identity
        assert_equal posted_batch.id, current.ingestion_batch_id
        assert pending.reload.withdrawn?
        assert_not pending.pending?
        assert_equal original_mapping, pending.entry_source.reload.attributes
        assert_equal bootstrap_batch.id, pending.entry_source.bootstrap_batch_id
        assert_equal original_batch, bootstrap_batch.reload.attributes
        assert_equal original_ciphertext, bootstrap_batch.read_attribute_before_type_cast("payload")

        resolver = Ingestion::MappedEntryResolver.new(external_account: context.external, account: context.account,
          definition: Provider::AccountData::Registry.declared_adapter(key).definition)
        assert resolver.resolve(source_record: pending, kind: "transaction", external_id: pending_record[:external_id],
          entryable_type: "Transaction").retired_alias?

        pending_replay = capture_page(context, pending_record)
        financial = [ entry.attributes, entry.transaction.reload.attributes ]
        assert_no_difference [ "Entry.count", "Transaction.count", "SourceRecord.count", "EntrySource.count" ] do
          publish(context, posted_batch)
          publish(context, pending_replay)
        end
        assert_equal financial, [ entry.reload.attributes, entry.transaction.reload.attributes ]
        assert_equal original_mapping, pending.entry_source.reload.attributes
        assert_equal original_batch, bootstrap_batch.reload.attributes
        assert_equal original_ciphertext, bootstrap_batch.read_attribute_before_type_cast("payload")
        assert context.control.reload.quiescing?
        assert context.external.provider_connection.disabled?
        assert_empty context.external.provider_connection.provider_sync_checkpoints.where(stream: "transactions")
      end
    end
  end

  private
    def with_copied_pending(key)
      with_provider_encryption do
        family = families(:dylan_family)
        timestamps = family.reload.attributes.slice("latest_sync_activity_at", "latest_sync_completed_at", "updated_at")
        item = case key
        when "akahu"
          AkahuItem.create!(family: family, name: "Pending bootstrap", app_token: "test-app-token", user_token: "test-user-token")
        when "lunchflow"
          LunchflowItem.create!(family: family, name: "Pending bootstrap", api_key: "test-api-key")
        when "redbark"
          RedbarkItem.create!(family: family, name: "Pending bootstrap", api_key: "test-api-key")
        end
        account = family.accounts.create!(name: "Retained pending account", currency: "USD", balance: 100,
          accountable: Depository.new, status: "active")
        begin
          manifest = Provider::AccountData::MigrationManifest.for(key)
          remote_column = key == "redbark" ? "redbark_account_id" : "account_id"
          source = manifest.account_type.constantize.create!(manifest.account_foreign_key => item.id,
            remote_column => "remote-account", name: "Checking", currency: "USD", raw_transactions_payload: [])
          link = AccountProvider.create!(account: account, provider: source)
          pending_record = normalized_record(key, pending: true)
          entry = account.entries.create!(source: key, external_id: pending_record[:external_id],
            date: pending_record[:date], amount: pending_record[:amount], currency: "USD",
            name: "Retained user description", notes: "Retained user notes",
            locked_attributes: { "name" => true, "notes" => true, "date" => true, "amount" => true, "currency" => true },
            entryable: Transaction.new(extra: { key => { "pending" => true } }))
          copier = Provider::AccountData::MigrationCopier.new(provider_key: key, legacy_item_id: item.id, batch_size: 1)
          control = nil
          15.times do
            control = copier.run_quiesced.reload
            break if control.high_water_mark["phase"] == "verified"
          end
          assert control.quiescing?
          assert_equal "verified", control.high_water_mark["phase"]
          external = control.provider_connection.external_accounts.sole
          mapping = control.provider_migration_mappings.find_by!(role: "external_account", external_account: external)
          Account::SourcePolicy.select!(account: account, account_provider: link.reload, resource: "transactions")
          context = IdentityBootstrapTestHelper::Context.new(family: family, item: item, source: source, account: account,
            link: link, copier: copier, control: control, mapping: mapping, external: external)
          yield context, entry, pending_record
        ensure
          cleanup_identity_source(item, account)
          Family.where(id: family.id).update_all(timestamps)
        end
      end
    end

    def normalized_record(key, pending:)
      account = { external_id: "remote-account", currency: "USD" }
      date = pending ? "2026-09-10" : "2026-09-12"
      id = pending ? nil : "posted"
      case key
      when "akahu"
        Provider::AccountData::Akahu.new(client: Object.new, timezone: "UTC").normalize_transaction(
          { _id: id, _account: "remote-account", amount: "-12", currency: "USD", date: date, description: "Provider description", pending: pending }, account: account)
      when "lunchflow"
        Provider::AccountData::Lunchflow.new(client: Object.new, timezone: "UTC", observed_at: Time.utc(2026, 9, 16), include_pending: true).normalize_transaction(
          { id: id, accountId: "remote-account", amount: "-12", currency: "USD", date: date, description: "Provider description", isPending: pending }, account: account)
      when "redbark"
        Provider::AccountData::Redbark.new(client: Object.new, timezone: "UTC", observed_at: Time.utc(2026, 9, 16), include_pending: true).normalize_transaction(
          { id: id || "pending", accountId: "remote-account", amount: "-12", date: date, description: "Provider description", status: pending ? "pending" : "posted" }, account: account)
      end
    end

    def capture_page(context, record)
      page = Provider::AccountData::Page.new(records: [ record ], complete: true, mode: "snapshot",
        coverage: { "pending_absence_authoritative" => false })
      policy = Account::SourcePolicy.active.find_by!(account: context.account, resource: "transactions")
      create_provider_batch(context.external.provider_connection, external_account: context.external,
        stream: "transactions", source_policy_version: policy.id, payload: Ingestion::Codec.dump(page))
    end

    def publish(context, batch)
      page = Ingestion::Codec.load(batch.reload.payload)
      context.external.provider_connection.with_lock do
        Ingestion::LedgerWriter.new(external_account: context.external, batch: batch).apply(page)
        batch.update!(status: "applied", applied_at: batch.applied_at || Time.current)
      end
    end
end
