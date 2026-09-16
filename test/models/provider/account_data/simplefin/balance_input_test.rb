require "test_helper"
require_relative "../../../../support/provider_ingestion_test_helper"

class Provider::AccountData::Simplefin::BalanceInputTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper, ActiveJob::TestHelper

  setup do
    DebugLogEntry.stubs(:capture)
    Account.any_instance.stubs(:sync_later)
    Provider::AccountData::Registry.stubs(:fetch).with("simplefin").returns(Provider::AccountData::Simplefin)
    Ingestion::BalancePolicies::Simplefin::Snapshot.stubs(:configuration).returns(
      "enabled" => true, "settings" => Ingestion::BalancePolicies::Simplefin::Snapshot::DEFAULTS.deep_dup)
  end

  test "fresh raw transactions classify sparse credit history before the new ledger entries can replace its baseline" do
    with_source do |connection, external, account, sync, client|
      expect_inventory_and_transactions(client, sync)

      perform(connection, sync)

      assert_equal BigDecimal("-30"), account.reload.balance
      assert_equal 10, account.entries.count
      assert_equal 2, account.entries.where("amount < 0 AND date >= ?", sync.created_at.to_date - 5).count
      page = balance_page(connection)
      snapshot = page.evidence.fetch("balance_policy")
      assert_equal 0, snapshot.dig("entry_metrics", "tx_count")
      assert_equal 10, snapshot.dig("raw_metrics", "tx_count")
      assert_equal false, snapshot.dig("raw_metrics", "recent_payment")
      assert_equal :credit, classify(snapshot).classification
      transaction = connection.ingestion_batches.find_by!(stream: "transactions")
      baseline = Ingestion::Codec.load(transaction.payload).evidence.fetch("balance_policy_baseline")
      assert_equal 0, baseline.dig("raw_metrics", "tx_count")
      assert_equal baseline.fetch("entry_metrics"), snapshot.fetch("entry_metrics")
      assert_equal transaction.id, page.evidence.dig("balance_policy_input", "baseline_batch_id")
      assert_equal transaction.id, page.evidence.dig("balance_policy_input", "transaction_checkpoint", "ingestion_batch_id")
      assert_equal "-30", page.evidence.dig("response", "accounts").sole.fetch("balance")
      assert_equal false, Ingestion::Codec.load(transaction.payload).coverage.fetch("pending_absence_authoritative")
      assert_equal "credit", external.reload.sensitive_details.dig("balance_policy_state", "simplefin", "value")
    end
  end

  test "pending preference limits fresh classification evidence while the complete raw response remains retained" do
    [ false, true ].each do |include_pending|
      with_source(include_pending: include_pending) do |connection, _external, account, sync, client|
        expect_inventory_and_transactions(client, sync, pending: include_pending, rows: transactions(sync, pending_payments: true))

        perform(connection, sync)

        expected_count = include_pending ? 10 : 8
        assert_equal expected_count, SourceRecord.where(ingestion_batch_id: connection.ingestion_batches.select(:id)).count
        snapshot = balance_page(connection).evidence.fetch("balance_policy")
        assert_equal expected_count, snapshot.dig("raw_metrics", "tx_count")
        assert_equal BigDecimal(include_pending ? "-30" : "30"), account.reload.balance
        raw = Ingestion::Codec.load(connection.ingestion_batches.find_by!(stream: "transactions").payload)
        assert_equal 10, raw.evidence.dig("response", "accounts").sole.fetch("transactions").size
        assert_equal include_pending, raw.coverage.fetch("pending_included")
      end
    end
  end

  test "secondary SimpleFIN transactions feed its selected balance classifier without posting ledger entries" do
    with_source do |connection, external, account, sync, client|
      other_connection = create_provider_connection
      other_external = create_external_account(other_connection)
      other_link = AccountProvider.create!(account: account, external_account: other_external)
      Account::SourcePolicy.select!(account: account, account_provider: other_link, resource: "transactions")
      expect_inventory_and_transactions(client, sync)

      perform(connection, sync)

      assert_equal BigDecimal("-30"), account.reload.balance
      assert_empty account.entries
      observations = SourceRecord.where(external_account: external, account: account)
      assert_equal 10, observations.count
      assert_empty EntrySource.where(source_record: observations)
      assert_equal 10, balance_page(connection).evidence.dig("balance_policy", "raw_metrics", "tx_count")
      assert_equal other_link.id, Account::SourcePolicy.active.find_by!(account: account, resource: "transactions").account_provider_id
    end
  end

  test "incomplete transactions preserve their evidence but never evaluate or write a balance" do
    with_source do |connection, external, account, sync, client|
      expect_inventory_and_transactions(client, sync, rows: transactions(sync) + [ nil ])
      Provider::AccountData::Simplefin.any_instance.expects(:fetch_balance).never

      assert_raises(Provider::AccountData::Error) { perform(connection, sync) }

      assert_equal BigDecimal("0"), account.reload.balance
      assert_equal 10, account.entries.count
      assert_empty connection.ingestion_batches.where(stream: "balances")
      assert_empty connection.provider_sync_checkpoints.where(stream: %w[balances transactions])
      assert_nil external.reload.sensitive_details.dig("balance_policy_state", "simplefin")
      assert_not connection.ingestion_batches.find_by!(stream: "transactions").complete?
    end
  end

  test "a deferred transaction prerequisite schedules the same Sync without turning skipped balances into a failure" do
    with_source do |connection, _external, account, sync, client|
      client.expects(:get_accounts_snapshot).with(@access_url, start_date: nil, end_date: nil, pending: true)
        .returns(accounts: [ raw_account(sync) ])
      resume_at = 30.seconds.from_now
      Provider::AccountData::Simplefin.any_instance.expects(:fetch_transactions)
        .raises(Provider::AccountData::DeferredPage.new(resume_at: resume_at))
      Provider::AccountData::Simplefin.any_instance.expects(:fetch_balance).never
      # This suite uses a rollback fixture transaction. Exercise the scheduling
      # decision here; committed queue delivery has separate Sync job coverage.
      SyncJob.stubs(:enqueue_after_transaction_commit).returns(false)

      assert_enqueued_with(job: SyncJob, args: [ sync ], at: resume_at) { SyncJob.perform_now(sync) }

      assert sync.reload.pending?
      assert_equal 1, sync.provider_attempt
      assert_equal resume_at, sync.resume_at
      assert_nil sync.error
      assert_equal BigDecimal("0"), account.reload.balance
      assert_empty connection.ingestion_batches.where(stream: "balances")
      assert_empty connection.provider_sync_checkpoints.where(stream: %w[transactions balances])
    end
  end

  test "a new attempt completing an interrupted stream keeps the first logical Sync baseline" do
    with_source do |connection, _external, account, sync, client|
      expect_inventory_and_transactions(client, sync, rows: transactions(sync) + [ nil ])
      assert_raises(Provider::AccountData::Error) { perform(connection, sync) }
      first = connection.ingestion_batches.find_by!(stream: "transactions")
      assert_equal 10, account.entries.count
      sync.update!(provider_attempt: 1)
      expect_transactions(client, sync, rows: transactions(sync))
      client.expects(:get_accounts_snapshot).with(@access_url, start_date: nil, end_date: nil, pending: true)
        .returns(accounts: [ raw_account(sync) ])

      perform(connection, sync)

      pages = connection.ingestion_batches.where(stream: "transactions").order(:writer_epoch).to_a
      assert_equal 2, pages.size
      assert_equal 10, Ingestion::Codec.load(pages.last.payload).evidence.dig("balance_policy_baseline", "entry_metrics", "tx_count")
      snapshot = balance_page(connection).evidence.fetch("balance_policy")
      assert_equal 0, snapshot.dig("entry_metrics", "tx_count")
      assert_equal first.id, balance_page(connection).evidence.dig("balance_policy_input", "baseline_batch_id")
      assert_equal pages.last.id, balance_page(connection).evidence.dig("balance_policy_input", "transaction_checkpoint", "ingestion_batch_id")
      assert_equal BigDecimal("-30"), account.reload.balance
      assert_equal 10, account.entries.count
    end
  end

  test "captured balance replay retains original entry metrics without fetching or accepting a new source binding" do
    with_source do |connection, external, account, sync, client|
      expect_inventory_and_transactions(client, sync)
      Account::ProviderImportAdapter.any_instance.expects(:update_balance).once
        .raises(Provider::AccountData::Error, "Simulated balance publication failure")
      assert_raises(Provider::AccountData::Error) { perform(connection, sync) }
      batch = connection.ingestion_batches.find_by!(stream: "balances")
      assert batch.captured?
      proof = Ingestion::Codec.load(batch.payload).evidence.fetch("request_inputs")
      Account::ProviderImportAdapter.any_instance.unstub(:update_balance)
      client.expects(:get_accounts_snapshot).never

      perform(connection, sync)

      assert batch.reload.applied?
      assert_equal BigDecimal("-30"), account.reload.balance
      assert_equal proof, Ingestion::Codec.load(batch.payload).evidence.fetch("request_inputs")
      assert_equal 0, balance_page(connection).evidence.dig("balance_policy", "entry_metrics", "tx_count")

      # A policy handover cannot make the old transaction baseline a proof of
      # the new resource authority, even for the same account and same Sync.
      other_connection = create_provider_connection
      other_link = AccountProvider.create!(account: account, external_account: create_external_account(other_connection))
      Account::SourcePolicy.select!(account: account, account_provider: other_link, resource: "transactions")
      assert_raises(Provider::AccountData::StaleWriter) do
        connection.with_lock do
          Provider::AccountData::Simplefin::BalanceInput.new(connection: connection, sync: sync, external_account: external.reload).capture
        end
      end
    end
  end

  private
    def with_source(include_pending: true)
      with_env_overrides("SIMPLEFIN_INCLUDE_PENDING" => nil) do
        travel_to Time.utc(2026, 9, 15, 12) do
          with_provider_encryption do
            Provider::AccountData::RuntimeContext.stubs(:pending_preference).returns(include_pending)
            @access_url = "https://private-user:private-password@bridge.example/access"
            client = mock("SimpleFIN snapshot transport")
            Provider::Simplefin.stubs(:new).returns(client)
            connection = create_provider_connection(provider_key: "simplefin", credentials: { "access_url" => @access_url },
              sync_start_date: Date.current - 30)
            external = create_external_account(connection, external_id: "sf-credit", name: "Credit card", account_type: "credit_card")
            account = connection.family.accounts.create!(name: "Fresh SimpleFIN credit history", currency: "USD", balance: 0, accountable: CreditCard.new)
            link = AccountProvider.create!(account: account, external_account: external)
            %w[transactions balances holdings].each do |resource|
              Account::SourcePolicy.select!(account: account, account_provider: link, resource: resource)
            end
            sync = connection.syncs.create!
            yield connection, external, account, sync, client
          end
        end
      end
    end

    def expect_inventory_and_transactions(client, sync, pending: true, rows: transactions(sync))
      client.expects(:get_accounts_snapshot).with(@access_url, start_date: nil, end_date: nil, pending: pending)
        .returns(accounts: [ raw_account(sync) ])
      expect_transactions(client, sync, pending: pending, rows: rows)
    end

    def expect_transactions(client, sync, pending: true, rows:)
      client.expects(:get_accounts_snapshot).with(@access_url, start_date: (sync.created_at.to_date - 30).to_time(:utc),
        end_date: sync.created_at, pending: pending).returns(accounts: [ raw_account(sync).merge(transactions: rows) ])
    end

    def raw_account(sync)
      { id: "sf-credit", name: "Credit card", currency: "USD", type: "credit_card", balance: "-30", "available-balance": "-30",
        "balance-date": sync.created_at.to_i, org: {}, holdings: [], transactions: transactions(sync) }
    end

    def transactions(sync, pending_payments: false)
      older = (sync.created_at - 10.days).to_i
      charges = 8.times.map { |index| { id: "charge-#{index}", amount: "-10", description: "Purchase #{index}", posted: older, transacted_at: older, pending: false } }
      payments = 2.times.map do |index|
        { id: "payment-#{index}", amount: "55", description: "Payment #{index}", pending: pending_payments,
          posted: pending_payments ? 0 : older, transacted_at: pending_payments ? older : (sync.created_at - 1.day).to_i }
      end
      charges + payments
    end

    def perform(connection, sync)
      Provider::AccountData::Syncer.new(connection.reload).perform_sync(sync.reload)
    end

    def balance_page(connection)
      Ingestion::Codec.load(connection.ingestion_batches.find_by!(stream: "balances").payload)
    end

    def classify(snapshot)
      Ingestion::BalancePolicies::Simplefin.new(snapshot: snapshot).call(observed_balance: BigDecimal("-30"))
    end
end
