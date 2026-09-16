require "test_helper"
require_relative "../../../support/identity_bootstrap_test_helper"

class Provider::AccountData::BrexMigrationCutoverTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  Cutover = Provider::AccountData::MigrationCutover
  Preparation = Provider::AccountData::MigrationPreparation
  Selection = Provider::AccountData::MigrationSourceSelection

  class Client
    attr_reader :requests, :inventory_requests

    def initialize(inventory, rows, &before_read)
      @inventory, @rows, @before_read, @requests = inventory, rows, before_read, []
      @inventory_requests = []
    end

    def get_cash_accounts_page(cursor:)
      @before_read.call
      @inventory_requests << "cash"
      { items: @inventory.fetch("cash_accounts"), next_cursor: nil }
    end

    def get_card_accounts_page(cursor:)
      @before_read.call
      @inventory_requests << "card"
      { items: @inventory.fetch("card_accounts"), next_cursor: nil }
    end

    def get_cash_transactions_page(remote_id, cursor:, start_date:)
      transactions(remote_id, start_date)
    end

    def get_primary_card_transactions_page(cursor:, start_date:)
      transactions("card_primary", start_date)
    end

    private
      def transactions(remote_id, start_date)
        @before_read.call
        @requests << { remote_id: remote_id, start: start_date }
        { items: @rows.is_a?(Hash) ? @rows.fetch(remote_id) : @rows, next_cursor: nil }
      end
  end

  setup do
    travel_to Time.utc(2026, 9, 16, 12)
    clear_enqueued_jobs
    DebugLogEntry.stubs(:capture)
    Account.any_instance.stubs(:sync_later)
    # Full handover behavior is exercised without activating the production port.
    Provider::AccountData::Brex.stubs(:native_ready?).returns(true)
  end

  teardown do
    clear_enqueued_jobs
    travel_back
  end

  test "cash and company card handovers preserve financial identity through the first native replay" do
    %w[cash card].each do |kind|
      with_source(kind: kind) do |context, inventory, rows|
        assert_empty Account::SourcePolicy.where(account: context.account)
        entry = context.account.entries.sole
        preparation = finish_preparation(context)
        entry.update!(name: "Retained user label", notes: "Retained user note", user_modified: true, import_locked: true)
        financial = identity_financial_snapshot(context)
        evidence = retained_evidence(context)
        link = context.link.reload.attributes
        policies = Account::SourcePolicy.where(account: context.account).order(:resource).map(&:attributes)
        assert_equal %w[balances transactions], policies.map { |policy| policy.fetch("resource") }
        result = nil

        queries = capture_sql_queries do
          assert_enqueued_with(job: SyncJob) { result = command(context).call }
        end

        assert_no_financial_sql(queries)
        assert_equal financial, identity_financial_snapshot(context)
        assert_equal evidence, retained_evidence(context)
        assert_equal link, context.link.reload.attributes
        assert_equal policies, Account::SourcePolicy.where(account: context.account).order(:resource).map(&:attributes)
        connection = context.control.provider_connection.reload
        receipt = context.control.reload.audit_results.fetch("native_cutover")
        assert_equal preparation.run_id, receipt.fetch("preparation_run_id")
        assert_equal({ context.external.id => "2026-09-08" }, receipt.fetch("account_starts"))
        assert_equal "2026-09-08", context.external.reload.metadata.fetch("brex_initial_history_start")
        assert context.control.active?
        assert connection.good?
        assert_equal 1, connection.writer_epoch
        assert_equal 1, context.control.writer_epoch
        sync = connection.syncs.sole
        assert_equal result.sync_id, sync.id
        assert_nil sync.window_start_date
        assert_raises(Provider::AccountData::LegacyWriterFence::OwnershipChanged) do
          BrexItem::Importer.new(context.item).import
        end

        client = Client.new(inventory, rows) { assert_equal 0, ApplicationRecord.connection.open_transactions }
        Provider::Brex.stubs(:new).returns(client)
        original_mapping = SourceRecord.where(external_account: context.external).sole.entry_source.attributes
        assert_no_difference [ "Entry.count", "Transaction.count", "SourceRecord.count", "EntrySource.count" ] do
          Provider::AccountData::Syncer.new(connection).perform_sync(sync)
        end
        assert_equal context.source.account_id, client.requests.sole.fetch(:remote_id)
        assert_equal Date.new(2026, 9, 8), Time.iso8601(client.requests.sole.fetch(:start)).getutc.to_date
        assert_equal entry.id, context.account.entries.sole.id
        assert_equal financial.fetch("entries"), identity_financial_snapshot(context).fetch("entries")
        assert_equal original_mapping, SourceRecord.where(external_account: context.external).sole.entry_source.attributes
        assert connection.provider_sync_checkpoints.find_by!(stream: "transactions").ingestion_batch.applied?
      end
    end
  end

  test "one cash and company card handover retains independent windows through staged inventory" do
    with_sources(kinds: %w[cash card], cached_dates: { "cash" => "2020-01-02", "card" => "2023-04-05" }) do |contexts, inventory, rows|
      cash, card = contexts
      finish_preparation(cash)
      expected_starts = { cash.external.id => "2020-01-02", card.external.id => "2023-04-05" }
      original_entries = contexts.to_h { |context| [ context.external.id, context.account.entries.sole.id ] }
      original_mappings = contexts.to_h do |context|
        [ context.external.id, SourceRecord.where(external_account: context.external).sole.entry_source.attributes ]
      end

      result = command(cash).call

      connection = cash.control.provider_connection.reload
      assert_equal expected_starts, cash.control.reload.audit_results.fetch("native_cutover").fetch("account_starts")
      sync = connection.syncs.find(result.sync_id)
      assert_nil sync.window_start_date
      client = Client.new(inventory, rows) { assert_equal 0, ApplicationRecord.connection.open_transactions }
      Provider::Brex.stubs(:new).returns(client)

      assert_no_difference [ "Entry.count", "Transaction.count", "SourceRecord.count", "EntrySource.count", "ExternalAccount.count" ] do
        Provider::AccountData::Syncer.new(connection).perform_sync(sync)
      end

      assert_equal %w[cash card], client.inventory_requests
      assert_equal({ "cash-remote" => "2020-01-02", "card_primary" => "2023-04-05" },
        client.requests.to_h { |request| [ request.fetch(:remote_id), Time.iso8601(request.fetch(:start)).getutc.to_date.iso8601 ] })
      assert_equal 2, client.requests.size
      contexts.zip(%w[cash card]).each do |context, kind|
        external = context.external.reload
        assert_equal kind, external.metadata.fetch("account_kind")
        assert_equal expected_starts.fetch(external.id), external.metadata.fetch("brex_initial_history_start")
        assert_equal original_entries.fetch(external.id), context.account.entries.sole.id
        assert_equal original_mappings.fetch(external.id), SourceRecord.where(external_account: external).sole.entry_source.attributes
        checkpoint = connection.provider_sync_checkpoints.find_by!(stream: "transactions", external_account: external)
        assert checkpoint.ingestion_batch.applied?
      end
      assert_equal "cc_payment", card.account.entries.sole.entryable.kind
      assert_equal BigDecimal("-25"), card.account.entries.sole.amount
      assert_equal "card_primary", card.external.external_id
      assert_equal 2, card.external.metadata.fetch("card_accounts_count")
    end
  end

  test "production Brex readiness rejects cutover without changing prepared ownership" do
    with_source do |context, _inventory, _rows|
      finish_preparation(context)
      Provider::AccountData::Brex.unstub(:native_ready?)
      refute Provider::AccountData::Brex.native_ready?
      before = ownership(context)

      assert_no_enqueued_jobs do
        assert_raises(Provider::AccountData::UnsupportedCapability) { command(context).call }
      end

      assert_equal before, ownership(context)
      assert_paused(context)
    end
  end

  test "overlapping providers require explicit authority and retain an independent balance source" do
    with_source do |context, _inventory, _rows|
      other = create_provider_connection(family: context.family, provider_key: "up")
      other_external = create_external_account(other)
      other_link = AccountProvider.create!(account: context.account, external_account: other_external)
      begin
        assert_raises(Selection::Conflict) { finish_preparation(context) }
        assert_empty Account::SourcePolicy.where(account: context.account)
        assert_empty SourceRecord.where(external_account: context.external)

        transaction_policy = Account::SourcePolicy.select!(account: context.account, account_provider: context.link.reload, resource: "transactions")
        balance_policy = Account::SourcePolicy.select!(account: context.account, account_provider: other_link, resource: "balances")
        policies = Account::SourcePolicy.where(account: context.account).order(:id).map(&:attributes)
        finish_preparation(context)
        command(context).call

        assert_equal policies, Account::SourcePolicy.where(account: context.account).order(:id).map(&:attributes)
        assert transaction_policy.reload.active?
        assert balance_policy.reload.active?
      ensure
        Account::SourcePolicy.where(account_provider: other_link).delete_all
        other_link.delete
        other.destroy!
      end
    end
  end

  test "unapplied cached cash and card rows cannot be excused by completed legacy syncs" do
    %w[cash card].each do |kind|
      with_source(kind: kind, import: false) do |context, _inventory, _rows|
        finish_preparation(context)
        before = ownership(context)
        assert_no_enqueued_jobs do
          assert_raises(Provider::AccountData::Brex::CutoverHistory::Conflict) { command(context).call }
        end
        assert_equal before, ownership(context)
        assert_empty context.account.entries
        assert_paused(context)
      end
    end
  end

  test "changed cached values invalidate the original Brex preparation" do
    with_source do |context, _inventory, rows|
      finish_preparation(context)
      context.source.update!(raw_transactions_payload: [ rows.sole.merge("amount" => money(9999)) ])
      financial = identity_financial_snapshot(context)
      evidence = retained_evidence(context)

      assert_no_enqueued_jobs do
        assert_raises(Provider::AccountData::MigrationCopier::SourceChanged, Provider::AccountData::MigrationCopier::Conflict,
          Preparation::Conflict, Cutover::Conflict) { command(context).call }
      end

      assert_equal financial, identity_financial_snapshot(context)
      assert_equal evidence, retained_evidence(context)
      assert_paused(context)
    end
  end

  test "failed native Sync installation rolls back all Brex ownership and history changes" do
    with_source do |context, _inventory, _rows|
      finish_preparation(context)
      before = ownership(context)
      external_before = context.external.reload.attributes
      connection_id = context.control.provider_connection_id
      failure = ->(sync) { raise IOError, "Cutover interrupted" if sync.syncable_type == "ProviderConnection" && sync.syncable_id == connection_id }
      Sync.set_callback(:create, :before, failure)
      begin
        assert_no_enqueued_jobs { assert_raises(IOError) { command(context).call } }
      ensure
        Sync.skip_callback(:create, :before, failure)
      end

      assert_equal before, ownership(context)
      assert_equal external_before, context.external.reload.attributes
      assert_paused(context)
    end
  end

  test "dispatch recovery reuses the committed Brex Sync after releasing transaction and permit" do
    with_source do |context, _inventory, _rows|
      finish_preparation(context)
      failure = ->(*) { raise IOError, "Queue unavailable" }
      assert_raises(IOError) { SyncJob.stub(:perform_later, failure) { command(context).call } }
      original = context.control.provider_connection.syncs.sole
      dispatch = lambda do |sync|
        assert_equal 0, ApplicationRecord.connection.open_transactions
        assert_nil ActiveSupport::IsolatedExecutionState[Provider::AccountData::LegacyWriterFence::CONTEXT_KEY]
        assert_equal original.id, sync.id
      end

      result = SyncJob.stub(:perform_later, dispatch) { command(context).call }

      assert result.replayed
      assert_equal original.id, result.sync_id
      assert_equal [ original.id ], context.control.provider_connection.syncs.pluck(:id)
    end
  end

  private
    def money(amount)
      { "amount" => amount, "currency" => "USD" }
    end

    def inventory(kind)
      if kind == "cash"
        cash = { "id" => "cash-remote", "name" => "Brex Cash", "account_kind" => "cash", "status" => "ACTIVE",
          "current_balance" => money(10_000), "available_balance" => money(8_000) }
        { "accounts" => [ cash ], "cash_accounts" => [ cash.deep_dup ], "card_accounts" => [] }
      else
        cards = [ 1, 2 ].map do |number|
          { "id" => "physical-card-#{number}", "account_kind" => "card", "status" => "ACTIVE",
            "current_balance" => money(5_000 * number), "available_balance" => money(50_000 - 5_000 * number),
            "account_limit" => money(50_000) }
        end
        aggregate = { "id" => "card_primary", "name" => "Brex Card", "account_kind" => "card", "status" => "ACTIVE",
          "current_balance" => money(15_000), "available_balance" => money(85_000), "account_limit" => money(100_000),
          "card_accounts_count" => 2, "raw_card_accounts" => cards.deep_dup }
        { "accounts" => [ aggregate ], "cash_accounts" => [], "card_accounts" => cards }
      end
    end

    def command(context)
      Cutover.new(provider_key: "brex", legacy_item_id: context.item.id, family: context.family, page_size: 1)
    end

    def finish_preparation(context)
      150.times do
        result = Preparation.new(provider_key: "brex", legacy_item_id: context.item.id, family: context.family, page_size: 1).run
        return result if result.awaiting_acceptance?
      end
      flunk "Brex preparation did not complete"
    end

    def with_source(kind: "cash", import: true)
      with_sources(kinds: [ kind ], import: import) do |contexts, payload, rows|
        context = contexts.sole
        yield context, payload, rows.fetch(context.source.account_id)
      end
    end

    def with_sources(kinds:, import: true, cached_dates: {})
      with_provider_encryption do
        family = families(:dylan_family)
        timestamps = family.reload.attributes.slice("latest_sync_activity_at", "latest_sync_completed_at", "updated_at")
        item = BrexItem.create!(family: family, name: "Brex cutover", token: "private-brex-token")
        accounts, sources, links, rows_by_remote = [], [], [], {}
        begin
          payload = %w[accounts cash_accounts card_accounts].to_h do |key|
            [ key, kinds.flat_map { |kind| inventory(kind).fetch(key) } ]
          end
          item.upsert_brex_snapshot!(payload)
          kinds.each do |kind|
            account = family.accounts.create!(name: "Existing Brex #{kind} account", currency: "USD", balance: kind == "card" ? 150 : 100,
              accountable: kind == "card" ? CreditCard.new : Depository.new, status: "active")
            accounts << account
            snapshot = payload.fetch("accounts").find { |raw| raw.fetch("account_kind") == kind }
            initiated_date = cached_dates.fetch(kind, "2026-09-12")
            posted_date = cached_dates.fetch(kind, "2026-09-13")
            rows = [ { "id" => "original", "account_id" => snapshot.fetch("id"), "amount" => money(kind == "card" ? -2500 : 1250),
              "type" => kind == "card" ? "COLLECTION" : "PURCHASE", "description" => "Original event",
              "initiated_at_date" => "#{initiated_date}T12:00:00Z", "posted_at_date" => "#{posted_date}T12:00:00Z" } ]
            source = item.brex_accounts.create!(account_id: snapshot.fetch("id"), name: snapshot.fetch("name"), currency: "USD",
              account_kind: kind, raw_transactions_payload: rows, created_at: Time.utc(2026, 9, 10))
            sources << source
            source.upsert_brex_snapshot!(snapshot)
            links << AccountProvider.create!(account: account, provider: source)
            assert BrexEntry::Processor.new(rows.sole, brex_account: source).process if import
            rows_by_remote[source.account_id] = rows
          end
          item.syncs.create!(status: "completed", completed_at: Time.utc(2026, 9, 15), created_at: Time.utc(2026, 9, 15))
          copier = Provider::AccountData::MigrationCopier.new(provider_key: "brex", legacy_item_id: item.id, batch_size: 1)
          control = nil
          20.times do
            control = copier.run_quiesced.reload
            break if control.high_water_mark["phase"] == "verified"
          end
          assert_equal "verified", control.high_water_mark["phase"]
          contexts = sources.each_with_index.map do |source, index|
            external = control.provider_connection.external_accounts.find_by!(external_id: source.account_id)
            mapping = control.provider_migration_mappings.find_by!(role: "external_account", external_account: external)
            IdentityBootstrapTestHelper::Context.new(family: family, item: item, source: source, account: accounts.fetch(index),
              link: links.fetch(index), copier: copier, control: control, mapping: mapping, external: external)
          end
          yield contexts, payload, rows_by_remote
        ensure
          connection = ProviderMigrationControl.find_by(legacy_type: "BrexItem", legacy_id: item.id)&.provider_connection
          connection&.update_columns(lease_owner: nil, lease_expires_at: nil, lease_sync_id: nil)
          Sync.where(syncable_type: "BrexItem", syncable_id: item.id).delete_all
          accounts.drop(1).each do |account|
            Account::SourcePolicy.where(account_id: account.id).delete_all
            AccountProvider.where(account_id: account.id).delete_all
          end
          cleanup_identity_source(item, accounts.first) if accounts.any?
          accounts.drop(1).each { |account| account.reload.destroy! }
          Sync.where(syncable_type: "ProviderConnection", syncable_id: connection.id).delete_all if connection
          Family.where(id: family.id).update_all(timestamps)
        end
      end
    end

    def ownership(context)
      { control: context.control.reload.attributes, connection: context.control.provider_connection.reload.attributes,
        syncs: context.control.provider_connection.syncs.order(:id).map(&:attributes) }
    end

    def retained_evidence(context)
      { batches: context.control.provider_connection.ingestion_batches.order(:id).pluck(:id, Arel.sql("payload::text")),
        observations: SourceRecord.where(external_account: context.external).order(:id).map(&:attributes),
        mappings: EntrySource.where(bootstrap_external_account: context.external).order(:id).map(&:attributes) }
    end

    def assert_paused(context)
      assert context.control.reload.quiescing?
      connection = context.control.provider_connection.reload
      assert connection.disabled?
      assert_equal 0, connection.writer_epoch
      assert_equal 0, context.control.writer_epoch
      assert_empty connection.syncs
    end
end
