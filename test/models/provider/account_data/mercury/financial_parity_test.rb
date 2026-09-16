require "test_helper"
require_relative "../../../../support/identity_bootstrap_test_helper"

class Provider::AccountData::Mercury::FinancialParityTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  setup do
    # Exercise real local publication without changing production readiness.
    Provider::AccountData::Mercury.stubs(:native_ready?).returns(true)
    Provider::Mercury.expects(:new).never
    DebugLogEntry.stubs(:capture)
    clear_enqueued_jobs
  end
  teardown { clear_enqueued_jobs }

  { "Depository" => 1, "CreditCard" => -1, "Loan" => -1, "OtherLiability" => 1 }.each do |type, sign|
    test "#{type} native balances preserve the legacy sign cash balance and currency" do
      %w[123.45 -12.34 0].each do |raw_balance|
        with_copied_source(rows: [], type: type, raw_balance: raw_balance) do |context|
          original_accountable_id = context.account.accountable_id
          legacy = context.account.reload.attributes.slice("balance", "cash_balance", "currency")
          assert_equal BigDecimal(raw_balance) * sign, legacy.fetch("balance")
          assert_equal legacy.fetch("balance"), legacy.fetch("cash_balance")
          assert_equal "USD", legacy.fetch("currency")
          context.account.update!(balance: 999, cash_balance: 999)

          adapter = Provider::AccountData::Mercury.new(client: Object.new, timezone: context.family.timezone)
          record = adapter.normalize_account(account_payload(raw_balance))
          page = adapter.fetch_balance(account: record)
          batch = capture_page(context, page, stream: "balances")
          assert_no_difference [ "Account.count", "Entry.count", "Transaction.count" ] do
            publish(context, batch)
          end

          assert_equal legacy, context.account.reload.attributes.slice("balance", "cash_balance", "currency")
          assert_equal original_accountable_id, context.account.accountable_id
          assert_equal type, context.account.accountable_type
        end
      end
    end
  end

  test "a signed legacy pending transaction posts on the same financial UUID and retains its original proof" do
    with_copied_source(rows: [ transaction(status: "pending", postedAt: nil) ]) do |context|
      entry = context.account.entries.sole
      original_ids = [ entry.id, entry.entryable_id ]
      observation = observation_for(context)
      proof = permanent_proof(observation)
      batch = transaction_batch(context, [ transaction(status: "sent", amount: "-15.25", note: "Posted note") ])

      assert_no_difference [ "Entry.count", "Transaction.count", "SourceRecord.count", "EntrySource.count" ] do
        publish(context, batch)
      end
      assert_equal original_ids, [ entry.reload.id, entry.entryable_id ]
      assert_equal "mercury_transaction", entry.external_id
      assert_equal BigDecimal("15.25"), entry.amount
      assert_equal "Posted note - Retained details", entry.notes
      assert_not entry.transaction.pending?
      assert_not observation.reload.pending?
      assert_equal batch.id, observation.ingestion_batch_id
      assert_equal proof, permanent_proof(observation)
    end
  end

  test "first native stale pending keeps a signed already booked observation and all protected fields unchanged" do
    with_copied_source do |context|
      entry = context.account.entries.sole
      entry.update!(name: "User description", notes: "User notes", amount: 27,
        user_modified: true, locked_attributes: { "name" => true, "amount" => true })
      observation = observation_for(context)
      before = financial_and_observation(entry, observation)
      proof = permanent_proof(observation)
      batch = transaction_batch(context, [ transaction(status: "pending", postedAt: nil, amount: "-999") ])

      assert_no_difference [ "Entry.count", "Transaction.count", "SourceRecord.count", "EntrySource.count" ] do
        publish(context, batch)
        publish(context, batch)
      end
      assert_equal before, financial_and_observation(entry, observation)
      assert_equal proof, permanent_proof(observation)
      assert_equal "migration", observation.ingestion_batch.origin_kind
      captured = Ingestion::Codec.load(batch.reload.payload)
      assert captured.records.sole[:pending]
      assert_equal BigDecimal("999"), captured.records.sole[:amount]
      assert_equal "pending", captured.evidence.fetch("response").with_indifferent_access.fetch(:transactions).sole.with_indifferent_access.fetch(:status)
      assert batch.applied?
    end
  end

  test "posted then stale pending then a newer posted update keeps identity and permits future corrections" do
    with_copied_source(rows: [ transaction(status: "pending", postedAt: nil) ]) do |context|
      entry = context.account.entries.sole
      observation = observation_for(context)
      proof = permanent_proof(observation)
      booked = transaction_batch(context, [ transaction(amount: "-15") ])
      publish(context, booked)
      before = financial_and_observation(entry, observation)
      publish(context, transaction_batch(context, [ transaction(status: "pending", postedAt: nil, amount: "-12.34") ]))
      assert_equal before, financial_and_observation(entry, observation)
      assert_equal booked.id, observation.ingestion_batch_id

      corrected = transaction_batch(context, [ transaction(amount: "-17.50", bankDescription: "Corrected posted description") ])
      assert_no_difference [ "Entry.count", "Transaction.count" ] { publish(context, corrected) }
      assert_equal BigDecimal("17.5"), entry.reload.amount
      assert_equal "Corrected posted description", entry.name
      assert_not entry.transaction.pending?
      assert_equal corrected.id, observation.reload.ingestion_batch_id
      assert_equal proof, permanent_proof(observation)
    end
  end

  test "pending observations may still receive same ID pending updates before posting" do
    with_copied_source(rows: [ transaction(status: "pending", postedAt: nil) ]) do |context|
      entry = context.account.entries.sole
      original_ids = [ entry.id, entry.entryable_id ]
      batch = transaction_batch(context, [ transaction(status: "pending", postedAt: nil, amount: "-14.75") ])
      publish(context, batch)
      assert_equal original_ids, [ entry.reload.id, entry.entryable_id ]
      assert_equal BigDecimal("14.75"), entry.amount
      assert entry.transaction.pending?
      assert observation_for(context).pending?
    end
  end

  test "a secondary stale pending observation cannot regress its booked posting after authority returns" do
    with_copied_source do |context|
      with_other_source(context) do |other_link|
        entry = context.account.entries.sole
        observation = observation_for(context)
        before = financial_and_observation(entry, observation)
        proof = permanent_proof(observation)
        Account::SourcePolicy.select!(account: context.account, account_provider: other_link, resource: "transactions")
        secondary = transaction_batch(context, [ transaction(status: "pending", amount: "-99") ])
        publish(context, secondary)
        assert_equal before, financial_and_observation(entry, observation)
        assert_equal proof, permanent_proof(observation)
        assert secondary.reload.applied?

        Account::SourcePolicy.select!(account: context.account, account_provider: context.link.reload, resource: "transactions")
        publish(context, transaction_batch(context, [ transaction(status: "pending", amount: "-199") ]))
        assert_equal before, financial_and_observation(entry, observation)
        corrected = transaction_batch(context, [ transaction(amount: "-17.50") ])
        assert_no_difference [ "Entry.count", "Transaction.count" ] { publish(context, corrected) }
        assert_equal BigDecimal("17.5"), entry.reload.amount
        assert_not entry.transaction.pending?
        assert_equal corrected.id, observation.reload.ingestion_batch_id
        assert_equal proof, permanent_proof(observation)
      end
    end
  end

  test "unmapped secondary booked evidence stays booked without obtaining financial authority" do
    with_copied_source(rows: []) do |context|
      with_other_source(context) do |other_link|
        Account::SourcePolicy.select!(account: context.account, account_provider: other_link, resource: "transactions")
        booked = transaction_batch(context, [ transaction ])
        assert_no_difference [ "Entry.count", "Transaction.count", "EntrySource.count" ] { publish(context, booked) }
        observation = observation_for(context)
        before = observation.attributes
        assert_not observation.pending?
        assert_nil observation.entry_source
        publish(context, transaction_batch(context, [ transaction(status: "pending") ]))
        assert_equal before, observation.reload.attributes
        assert_empty context.account.entries

        Account::SourcePolicy.select!(account: context.account, account_provider: context.link.reload, resource: "transactions")
        assert_no_difference [ "Entry.count", "Transaction.count", "EntrySource.count" ] do
          publish(context, transaction_batch(context, [ transaction(status: "pending") ]))
        end
        assert_equal before, observation.reload.attributes
        publish(context, transaction_batch(context, [ transaction(amount: "-18") ]))
        assert_equal BigDecimal("18"), context.account.entries.sole.amount
        assert_equal context.account.entries.sole.id, observation.reload.entry_source.entry_identity
      end
    end
  end

  test "secondary stale pending still refuses a missing signed posting proof" do
    with_copied_source do |context|
      with_other_source(context) do |other_link|
        observation = observation_for(context)
        observation.entry_source.delete
        entry = context.account.entries.sole
        before = financial_and_observation(entry, observation)
        Account::SourcePolicy.select!(account: context.account, account_provider: other_link, resource: "transactions")
        batch = transaction_batch(context, [ transaction(status: "pending") ])
        assert_raises(Ingestion::MappedEntryResolver::Conflict) { publish(context, batch) }
        assert_equal before, financial_and_observation(entry, observation)
        assert_not batch.reload.applied?
      end
    end
  end

  test "posting a user modified legacy pending entry only clears its pending flag" do
    with_copied_source(rows: [ transaction(status: "pending", postedAt: nil) ]) do |context|
      entry = context.account.entries.sole
      entry.update!(name: "User name", notes: "User notes", amount: 44, user_modified: true)
      before = entry.reload.attributes.except("updated_at")
      transaction_id = entry.entryable_id
      publish(context, transaction_batch(context, [ transaction(amount: "-99", bankDescription: "Provider name") ]))
      assert_equal before, entry.reload.attributes.except("updated_at")
      assert_equal transaction_id, entry.entryable_id
      assert_not entry.transaction.pending?
      assert_not observation_for(context).pending?
    end
  end

  test "excluded import locked and reconciled entries retain their financial values and pending flags" do
    [ { excluded: true }, { import_locked: true }, { reconciled_at: Time.current } ].each do |protection|
      with_copied_source(rows: [ transaction(status: "pending", postedAt: nil) ]) do |context|
        entry = context.account.entries.sole
        entry.update!(protection)
        financial = [ entry.reload.attributes, entry.transaction.attributes ]
        batch = transaction_batch(context, [ transaction(amount: "-99") ])
        publish(context, batch)
        assert_equal financial, [ entry.reload.attributes, entry.transaction.reload.attributes ]
        assert entry.transaction.pending?
        assert_not observation_for(context).pending?
        # Protection may leave the ledger badge pending; the provider baseline
        # remains booked and must not regress on another pending observation.
        before = financial_and_observation(entry, observation_for(context))
        publish(context, transaction_batch(context, [ transaction(status: "pending", amount: "-199") ]))
        assert_equal before, financial_and_observation(entry, observation_for(context))
      end
    end
  end

  test "failed rows stay captured evidence without creating or withdrawing financial entries" do
    failed = transaction(id: "failed-new", status: "failed")
    with_copied_source(rows: [ transaction(status: "pending", postedAt: nil), failed ]) do |context|
      assert_equal [ "mercury_transaction" ], context.account.entries.pluck(:external_id)
      entry = context.account.entries.sole
      observation = observation_for(context)
      before = financial_and_observation(entry, observation)
      batch = transaction_batch(context, [ failed, transaction(status: "failed") ])
      page = Ingestion::Codec.load(batch.payload)
      assert_empty page.records
      assert_empty page.removed_ids
      assert_equal "delta", page.mode
      assert_equal [ { "code" => "failed_transactions_excluded", "count" => 2 } ], page.warnings
      assert_no_difference [ "Entry.count", "Transaction.count", "SourceRecord.count", "EntrySource.count" ] do
        publish(context, batch)
      end
      assert_equal before, financial_and_observation(entry, observation)
      assert entry.transaction.pending?
      assert_not observation.withdrawn?
      assert_equal 2, page.evidence.fetch("response").with_indifferent_access.fetch(:transactions).size
    end
  end

  test "stale pending refuses a missing permanent mapping instead of silently accepting its ID" do
    with_copied_source do |context|
      observation = observation_for(context)
      observation.entry_source.delete
      entry = context.account.entries.sole
      before = financial_and_observation(entry, observation)
      batch = transaction_batch(context, [ transaction(status: "pending") ])
      assert_raises(Ingestion::MappedEntryResolver::Conflict) { publish(context, batch) }
      assert_equal before, financial_and_observation(entry, observation)
      assert_not batch.reload.applied?
    end
  end

  test "stale pending refuses a withdrawn observation before the no-write return" do
    with_copied_source do |context|
      observation = observation_for(context)
      observation.update!(withdrawn: true)
      entry = context.account.entries.sole
      before = financial_and_observation(entry, observation)
      batch = transaction_batch(context, [ transaction(status: "pending") ])
      assert_raises(Ingestion::MappedEntryResolver::Conflict) { publish(context, batch) }
      assert_equal before, financial_and_observation(entry, observation)
      assert_not batch.reload.applied?
    end
  end

  test "captured transaction status contract must match the declaring adapter" do
    with_copied_source do |context|
      entry = context.account.entries.sole
      observation = observation_for(context)
      before = financial_and_observation(entry, observation)
      [ nil, "unknown_policy" ].each do |policy|
        record = native_page(context, [ transaction(status: "pending") ]).records.sole
        attributes = record.attributes.deep_dup
        if policy
          attributes[:metadata][:transaction_status_policy] = policy
        else
          attributes[:metadata].delete(:transaction_status_policy)
        end
        page = Provider::AccountData::Page.new(records: [ Ingestion::Record.transaction(**attributes) ], complete: true, mode: "delta")
        batch = capture_page(context, page)
        assert_raises(Provider::AccountData::InvalidResponse) { publish(context, batch) }
        assert_equal before, financial_and_observation(entry, observation)
        assert_not batch.reload.applied?
      end
    end
  end

  test "a captured stale pending page still rejects a changed source policy" do
    with_copied_source do |context|
      entry = context.account.entries.sole
      observation = observation_for(context)
      batch = transaction_batch(context, [ transaction(status: "pending") ])
      before = financial_and_observation(entry, observation)
      Account::SourcePolicy.active.find_by!(account: context.account, resource: "transactions").update!(active: false)
      Account::SourcePolicy.select!(account: context.account, account_provider: context.link.reload, resource: "transactions")
      assert_raises(Provider::AccountData::StaleWriter) { publish(context, batch) }
      assert_equal before, financial_and_observation(entry, observation)
      assert_not batch.reload.applied?
    end
  end

  private
    def transaction(**changes)
      { id: "transaction", accountId: "mercury-remote", amount: "-12.34", status: "sent",
        bankDescription: "Retained coffee", kind: "card", note: "Retained note", details: "Retained details",
        createdAt: "2026-01-01T12:00:00Z", postedAt: "2026-01-02T12:00:00Z" }.merge(changes)
    end

    def account_payload(balance)
      { id: "mercury-remote", name: "Mercury source", type: "checking", currentBalance: balance }
    end

    def with_copied_source(rows: [ transaction ], type: "Depository", raw_balance: "123.45")
      with_provider_encryption do
        family = families(:dylan_family)
        timestamps = family.reload.attributes.slice("latest_sync_activity_at", "latest_sync_completed_at", "updated_at")
        item = MercuryItem.create!(family: family, name: "Mercury parity", token: "private-test-token")
        account = family.accounts.create!(name: "Retained Mercury", currency: "USD", balance: 100, accountable: type.constantize.new)
        begin
          source = item.mercury_accounts.create!(account_id: "mercury-remote", name: "Mercury source", currency: "USD",
            current_balance: BigDecimal(raw_balance), raw_payload: account_payload(raw_balance), raw_transactions_payload: rows)
          link = AccountProvider.create!(account: account, provider: source)
          MercuryAccount::Processor.new(source).process
          assert_equal rows.reject { |row| row[:status] == "failed" }.size, account.entries.count
          copier = Provider::AccountData::MigrationCopier.new(provider_key: "mercury", legacy_item_id: item.id, batch_size: 1)
          control = nil
          20.times do
            control = copier.run_quiesced.reload
            break if control.high_water_mark["phase"] == "verified"
          end
          assert_equal "verified", control.high_water_mark["phase"]
          external = control.provider_connection.external_accounts.sole
          mapping = control.provider_migration_mappings.find_by!(role: "external_account", external_account: external)
          %w[transactions balances].each do |resource|
            Account::SourcePolicy.select!(account: account, account_provider: link.reload, resource: resource)
          end
          context = IdentityBootstrapTestHelper::Context.new(family: family, item: item, source: source, account: account,
            link: link, copier: copier, control: control, mapping: mapping, external: external)
          financial = identity_financial_snapshot(context)
          result = nil
          10.times do
            result = Ingestion::IdentityBootstrap.new(mapping: mapping, family: family, page_size: 1).run
            break if result.verified?
          end
          assert result.verified?
          assert_equal financial, identity_financial_snapshot(context)
          yield context
        ensure
          Sync.where(syncable_type: "MercuryItem", syncable_id: item.id).delete_all
          cleanup_identity_source(item, account)
          Family.where(id: family.id).update_all(timestamps)
        end
      end
    end

    def observation_for(context)
      SourceRecord.find_by!(external_account: context.external, external_id: "mercury_transaction")
    end

    def with_other_source(context)
      connection = create_provider_connection(family: context.family, provider_key: "up")
      external = create_external_account(connection)
      link = AccountProvider.create!(account: context.account, external_account: external)
      yield link
    ensure
      Account::SourcePolicy.where(account_provider_id: link.id).delete_all if link
      link&.delete
      connection&.destroy!
    end

    def permanent_proof(observation)
      mapping = observation.entry_source.reload
      batch = IngestionBatch.find(mapping.bootstrap_batch_id)
      [ mapping.attributes, batch.attributes, batch.read_attribute_before_type_cast("payload") ]
    end

    def financial_and_observation(entry, observation)
      [ entry.reload.attributes, entry.transaction.reload.attributes, observation.reload.attributes ]
    end

    def native_page(context, rows)
      client = mock("Mercury native page transport")
      window = { start: "2026-01-01", end: "2026-01-31" }
      client.expects(:get_account_transactions_page).with("mercury-remote", cursor: nil, start_date: window[:start], end_date: window[:end])
        .returns(items: rows, next_cursor: nil)
      Provider::AccountData::Mercury.new(client: client, timezone: context.family.timezone)
        .fetch_transactions(account: { external_id: context.external.external_id, currency: "USD" }, window: window)
    end

    def transaction_batch(context, rows)
      capture_page(context, native_page(context, rows))
    end

    def capture_page(context, page, stream: "transactions")
      policy = Account::SourcePolicy.active.find_by!(account: context.account, resource: stream)
      create_provider_batch(context.external.provider_connection, external_account: context.external,
        stream: stream, source_policy_version: policy.id, mode: page.mode, complete: page.complete?, payload: Ingestion::Codec.dump(page))
    end

    def publish(context, batch)
      page = Ingestion::Codec.load(batch.reload.payload)
      context.external.provider_connection.with_lock do
        Ingestion::LedgerWriter.new(external_account: context.external, batch: batch).apply(page)
        batch.update!(status: "applied", applied_at: batch.applied_at || Time.current)
      end
    end
end
