require "test_helper"
require_relative "../../../support/identity_bootstrap_test_helper"

class Provider::AccountData::QuestradeLegacyIdentitiesTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  setup do
    DebugLogEntry.stubs(:capture)
    Provider::AccountData::Questrade.stubs(:native_ready?).returns(true)
    Provider::Questrade.expects(:new).never
    clear_enqueued_jobs
  end

  teardown { clear_enqueued_jobs }

  test "legacy trades fees cash and journals keep financial UUIDs through native exact-decimal replay" do
    with_source do |context, json|
      original = context.account.entries.order(:external_id).pluck(:external_id, :id, :entryable_type, :entryable_id)
      publish_identities(context)
      bootstrap = SourceRecord.where(external_account: context.external).to_h do |observation|
        [ observation.external_id, observation.entry_source.attributes.slice("id", "entry_identity", "bootstrap_batch_id") ]
      end
      enter_native(context)
      page = native_page(context, json)

      assert_equal original.map(&:first).sort, page.records.map { |record| record[:external_id] }.sort
      assert_equal 4, page.records.size
      assert_equal BigDecimal("0.00001"), page.records.find { |record| record[:activity_type] == "buy" }[:quantity]
      assert_equal BigDecimal("-0.00001"), page.records.find { |record| record[:metadata]&.dig(:investment_activity_label) == "Transfer" }[:quantity]

      2.times do
        batch = nil
        assert_no_difference [ "Entry.count", "Trade.count", "Transaction.count", "SourceRecord.count", "EntrySource.count" ] do
          batch = apply_page(context, page)
        end
        assert_equal original, context.account.entries.order(:external_id).pluck(:external_id, :id, :entryable_type, :entryable_id)
        SourceRecord.where(external_account: context.external).each do |observation|
          assert_equal batch.id, observation.ingestion_batch_id
          assert_equal observation.external_id, observation.input_external_id
          assert_equal bootstrap.fetch(observation.external_id),
            observation.entry_source.attributes.slice("id", "entry_identity", "bootstrap_batch_id")
        end
      end
    end
  end

  test "post-bootstrap user edits survive the change from legacy Float parsing to exact decimals" do
    with_source do |context, json|
      publish_identities(context)
      context.account.entries.each do |entry|
        entry.update!(name: "My retained description", notes: "Keep my note", user_modified: true, import_locked: true)
      end
      original = identity_financial_snapshot(context)
      enter_native(context)

      apply_page(context, native_page(context, json))

      assert_equal original, identity_financial_snapshot(context)
    end
  end

  private
    def activity_json
      <<~JSON
        [{"type":"Trades","action":"Buy","symbol":"AAPL","symbolId":456,
          "quantity":0.00001,"price":10000000.0,"netAmount":-100.5,"commission":-0.5,
          "description":"Original Questrade trade","currency":"CAD","transactionDate":"2026-09-11T12:00:00Z"},
         {"type":"Deposits","action":"CON","symbol":"","symbolId":0,
          "quantity":0.0,"netAmount":1.23456789,"description":"Original Questrade deposit",
          "currency":"CAD","transactionDate":"2026-09-12T12:00:00Z"},
         {"type":"Transfers","action":"JNL","symbol":"AAPL","symbolId":456,
          "quantity":-0.00001,"netAmount":0.0,"description":"Original Questrade journal",
          "currency":"CAD","transactionDate":"2026-09-13T12:00:00Z"}]
      JSON
    end

    def with_source
      with_provider_encryption do
        family = families(:dylan_family)
        timestamps = family.reload.attributes.slice("latest_sync_activity_at", "latest_sync_completed_at", "updated_at")
        item = QuestradeItem.create!(family: family, name: "Questrade identities", refresh_token: "private-refresh")
        account = family.accounts.create!(name: "Retained Questrade investment", currency: "CAD", balance: 100,
          accountable: Investment.new, status: "active")
        begin
          json = activity_json
          source = item.questrade_accounts.create!(name: "Questrade account", questrade_account_id: "123", currency: "CAD",
            current_balance: 100, cash_balance: 0, raw_payload: {}, raw_activities_payload: JSON.parse(json))
          link = AccountProvider.create!(account: account, provider: source)
          # Exercise the actual old processor's identity algorithm before copy.
          # It resolves the existing AAPL fixture without a market-data request.
          result = QuestradeAccount::ActivitiesProcessor.new(source.reload).process
          assert_equal({ trades: 2, transactions: 2 }, result)
          assert_equal 4, account.entries.count
          copier = Provider::AccountData::MigrationCopier.new(provider_key: "questrade", legacy_item_id: item.id, batch_size: 1)
          control = nil
          15.times do
            control = copier.run_quiesced.reload
            break if control.high_water_mark["phase"] == "verified"
          end
          assert_equal "verified", control.high_water_mark["phase"]
          external = control.provider_connection.external_accounts.sole
          mapping = control.provider_migration_mappings.find_by!(role: "external_account", external_account: external)
          Account::SourcePolicy.select!(account: account, account_provider: link.reload, resource: "activities")
          context = IdentityBootstrapTestHelper::Context.new(family: family, item: item, source: source, account: account,
            link: link, copier: copier, control: control, external: external, mapping: mapping)
          yield context, json
        ensure
          connection = ProviderMigrationControl.find_by(legacy_type: "QuestradeItem", legacy_id: item.id)&.provider_connection
          cleanup_identity_source(item, account)
          Sync.where(syncable_type: "ProviderConnection", syncable_id: connection.id).delete_all if connection
          Family.where(id: family.id).update_all(timestamps)
        end
      end
    end

    def publish_identities(context)
      publisher = Ingestion::IdentityBootstrap.new(mapping: context.mapping, family: context.family)
      result = nil
      10.times do
        result = publisher.run
        break if result.verified?
      end
      assert result.verified?
    end

    def enter_native(context)
      context.control.update!(state: "active", writer_epoch: 1)
      context.external.provider_connection.update!(status: "good", writer_epoch: 1)
    end

    def native_page(context, json)
      adapter = Provider::AccountData::Questrade.new(client: nil, timezone: context.family.timezone, observed_at: Time.current)
      account = adapter.normalize_account(number: context.external.external_id, type: "TFSA")
      # This is the production IngestionClient's JSON decoding contract.
      rows = JSON.parse(json, decimal_class: BigDecimal)
      Provider::AccountData::Page.new(records: rows.flat_map { |row| adapter.normalize_activity(row, account: account) },
        complete: true, mode: "delta", evidence: { response: rows })
    end

    def apply_page(context, page)
      policy = Account::SourcePolicy.active.find_by!(account: context.account, resource: "activities")
      batch = create_provider_batch(context.external.provider_connection, external_account: context.external, stream: "activities",
        scope_key: "account:#{context.external.id}", source_policy_version: policy.id, mode: page.mode, complete: page.complete?,
        payload: Ingestion::Codec.dump(page))
      securities = Ingestion::SecurityResolver.new(account: context.account).resolve(page)
      ApplicationRecord.transaction(requires_new: true) do
        Ingestion::LedgerWriter.new(external_account: context.external, batch: batch, securities: securities).apply(page)
        batch.update!(status: "applied", applied_at: Time.current)
      end
      batch
    end
end
