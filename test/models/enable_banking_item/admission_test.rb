require "test_helper"
require "timeout"
require_relative "../../support/provider_ingestion_test_helper"

class EnableBankingItem::AdmissionTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false
  Access = EnableBankingItem::LegacyAccess
  Fence = Access::Fence

  setup do
    DebugLogEntry.stubs(:capture)
    Sentry.stubs(:capture_exception)
    Setting.stubs(:syncs_include_pending).returns(false)
    Account.any_instance.stubs(:sync_later)
  end

  test "quiescing and native ownership deny every public writer before transport or progress" do
    Provider::EnableBanking.expects(:new).never
    %w[quiescing active retired rollback_pending].each do |state|
      with_source do |item, source, account|
        source.update!(raw_transactions_payload: [ transaction ])
        sync = item.syncs.create!(status_text: "Original progress", sync_stats: { "sentinel" => 1 })
        ProviderMigrationControl.create!(family: item.family, provider_key: "enable_banking",
          legacy_type: "EnableBankingItem", legacy_id: item.id, state: state,
          writer_epoch: state == "quiescing" ? 0 : 1)
        original = [ item, source, account, sync ].map { |record| record.reload.attributes }
        client = client_for(source)
        operations = [
          -> { EnableBankingItem::Importer.new(item, enable_banking_provider: client).import },
          -> { EnableBankingItem::Syncer.new(item).perform_sync(sync) },
          -> { item.import_latest_enable_banking_data },
          -> { item.process_accounts },
          -> { item.schedule_account_syncs(parent_sync: sync) },
          -> { item.upsert_enable_banking_snapshot!({ accounts: [] }) },
          -> { source.upsert_enable_banking_snapshot!({ uid: source.uid, currency: "EUR" }) },
          -> { source.upsert_enable_banking_transactions_snapshot!([ transaction ]) },
          -> { EnableBankingAccount::Processor.new(source).process },
          -> { EnableBankingAccount::Transactions::Processor.new(source).process },
          -> { EnableBankingEntry::Processor.new(transaction, enable_banking_account: source).process }
        ]
        assert_no_difference [ "Entry.count", "Transaction.count", "Merchant.count", "Sync.count" ] do
          operations.each { |operation| assert_raises(Fence::OwnershipChanged, &operation) }
        end
        assert_empty client.requests
        assert_equal original, [ item, source, account, sync ].map { |record| record.reload.attributes }
      end
    end
  end

  test "import holds an actual item permit over HTTP and publishes the fresh cache before financial processing" do
    with_source do |item, source, account|
      client = client_for(source) do |_phase|
        assert_equal :busy, drain_in_another_session(item)
      end
      result = EnableBankingItem::Importer.new(item, enable_banking_provider: client).import
      assert result[:success]
      assert_equal [ :session, :balances, :transactions ], client.requests
      assert_equal BigDecimal("55.25"), source.reload.current_balance
      assert_equal [ "transaction-1" ], source.raw_transactions_payload.map { |row| row.fetch("transaction_id") }
      assert_equal BigDecimal("10"), account.reload.balance
      assert_empty account.entries
      assert_equal :drained, drain_in_another_session(item)

      processed = EnableBankingAccount::Processor.new(source).process
      assert processed[:success]
      assert_equal BigDecimal("55.25"), account.reload.balance
      assert_equal BigDecimal("55.25"), account.cash_balance
      entry = account.entries.where(entryable_type: "Transaction").sole
      assert_equal "enable_banking_transaction-1", entry.external_id
      assert_equal BigDecimal("12.5"), entry.amount
      assert_equal "EUR", entry.currency
      refute entry.transaction.pending?
      assert_equal 1, account.entries.where(entryable_type: "Valuation").count
    end
  end

  test "the direct Syncer imports and publishes its own currency change with the original Sync" do
    with_source do |item, source, account|
      client = client_for(source, currency: "USD")
      EnableBankingItem.any_instance.stubs(:enable_banking_provider).returns(client)
      sync = item.syncs.create!(status: "syncing")
      scheduled = []
      Account.any_instance.stubs(:sync_later).with do |**arguments|
        scheduled << arguments
        true
      end

      EnableBankingItem::Syncer.new(item).perform_sync(sync)

      assert_equal [ :session, :balances, :transactions ], client.requests
      assert_equal "USD", source.reload.currency
      assert_equal "USD", account.reload.currency
      assert_equal BigDecimal("55.25"), account.balance
      entry = account.entries.where(entryable_type: "Transaction").sole
      assert_equal "USD", entry.currency
      assert_equal BigDecimal("12.5"), entry.amount
      refute item.reload.pending_account_setup?
      assert_equal 0, sync.reload.sync_stats.fetch("total_errors", 0)
      assert scheduled.any? { |arguments| arguments[:parent_sync]&.id == sync.id }
    end
  end

  test "a foreign or cancelled original Sync refuses before HTTP or progress writes" do
    with_source do |item, source, account|
      client = client_for(source)
      EnableBankingItem.any_instance.stubs(:enable_banking_provider).returns(client)
      other = create_item(item.family, "Other consent")
      foreign = other.syncs.create!(status_text: "Foreign progress")
      cancelled = item.syncs.create!(status_text: "Cancelled progress", cancel_requested_at: Time.current)
      original = [ foreign, cancelled ].map(&:attributes)

      [ foreign, cancelled ].each do |sync|
        assert_raises(Fence::OwnershipChanged) { EnableBankingItem::Syncer.new(item).perform_sync(sync) }
      end

      assert_empty client.requests
      assert_equal original, [ foreign, cancelled ].map { |sync| sync.reload.attributes }
      assert_empty account.entries
      assert_equal BigDecimal("10"), account.reload.balance
    end
  end

  test "same family relinking during balance HTTP cannot publish the old response into either account" do
    with_source do |item, source, account|
      replacement = create_account(item.family, "Replacement")
      client = client_for(source) do |phase|
        source.account_provider.update!(account: replacement) if phase == :balances
      end

      assert_raises(Fence::OwnershipChanged) do
        EnableBankingItem::Importer.new(item, enable_banking_provider: client).import
      end

      assert_equal [ :session, :balances ], client.requests
      assert_equal replacement.id, source.reload.account_provider.account_id
      assert_equal BigDecimal("25"), source.current_balance
      assert_equal [], source.raw_transactions_payload
      [ account, replacement ].each do |financial|
        assert_equal BigDecimal("10"), financial.reload.balance
        assert_empty financial.entries
      end
    end
  end

  test "a newer cache saved during transaction HTTP is retained while the old response is refused" do
    with_source do |item, source, account|
      newer = transaction.merge("transaction_id" => "newer-transaction")
      client = client_for(source) do |phase|
        source.update!(raw_transactions_payload: [ newer ]) if phase == :transactions
      end

      assert_raises(Fence::OwnershipChanged) do
        EnableBankingItem::Importer.new(item, enable_banking_provider: client).import
      end

      assert_equal [ newer ], source.reload.raw_transactions_payload
      # The preceding independent balance capture has already committed.
      assert_equal BigDecimal("55.25"), source.current_balance
      assert_equal BigDecimal("10"), account.reload.balance
      assert_empty account.entries
    end
  end

  test "consent changed during session HTTP is never replaced or adopted by the original importer" do
    with_source do |item, source, account|
      original_source = source.attributes
      replacement_session = SecureRandom.uuid
      client = client_for(source) do |phase|
        item.update!(session_id: replacement_session) if phase == :session
      end

      assert_raises(Fence::OwnershipChanged) do
        EnableBankingItem::Importer.new(item, enable_banking_provider: client).import
      end

      assert_equal [ :session ], client.requests
      assert_equal replacement_session, item.reload.session_id
      assert_nil item.raw_payload
      assert_equal original_source, source.reload.attributes
      assert_empty account.entries
    end
  end

  test "importer and Syncer constructors pin the original application and consent before any HTTP" do
    %i[application_id session_id].each do |attribute|
      with_source do |item, source, account|
        client = client_for(source)
        EnableBankingItem.any_instance.stubs(:enable_banking_provider).returns(client)
        importer = EnableBankingItem::Importer.new(item, enable_banking_provider: client)
        syncer = EnableBankingItem::Syncer.new(item)
        sync = item.syncs.create!(status: "syncing", status_text: "Unchanged")
        item.update!(attribute => SecureRandom.uuid)
        original = [ item, source, sync ].map { |record| record.reload.attributes }

        assert_raises(Fence::OwnershipChanged) { importer.import }
        assert_raises(Fence::OwnershipChanged) { syncer.perform_sync(sync) }

        assert_empty client.requests
        assert_equal original, [ item, source, sync ].map { |record| record.reload.attributes }
        assert_empty account.entries
      end
    end
  end

  test "already constructed financial processors reject later cache link and consent changes" do
    %i[cache link consent].each do |change|
      with_source do |item, source, account|
        source.update!(raw_transactions_payload: [ transaction ])
        processors = [
          EnableBankingAccount::Processor.new(source),
          EnableBankingAccount::Transactions::Processor.new(source),
          EnableBankingEntry::Processor.new(transaction, enable_banking_account: source)
        ]
        case change
        when :cache then source.update!(raw_transactions_payload: [ transaction.merge("transaction_id" => "replacement") ])
        when :link then source.account_provider.update!(account: create_account(item.family, "Replacement"))
        when :consent then item.update!(session_id: SecureRandom.uuid)
        end
        original = [ item, source, account ].map { |record| record.reload.attributes }

        assert_no_difference [ "Entry.count", "Transaction.count", "Merchant.count" ] do
          processors.each { |processor| assert_raises(Fence::OwnershipChanged) { processor.process } }
        end

        assert_equal original, [ item, source, account ].map { |record| record.reload.attributes }
      end
    end
  end

  test "the importer result cannot process a replacement cache link or consent" do
    %i[cache link consent].each do |change|
      with_source do |item, source, account|
        result = EnableBankingItem::Importer.new(item, enable_banking_provider: client_for(source)).import
        assert result[:success]
        case change
        when :cache then source.update!(raw_transactions_payload: [ transaction.merge("transaction_id" => "replacement") ])
        when :link then source.account_provider.update!(account: create_account(item.family, "Replacement"))
        when :consent then item.update!(session_id: SecureRandom.uuid)
        end
        original = source.reload.attributes

        assert_no_difference [ "Entry.count", "Transaction.count", "Merchant.count" ] do
          assert_raises(Fence::OwnershipChanged) do
            item.process_accounts(expected_contexts: result.fetch(:admitted_source_contexts),
              expected_item_context: result.fetch(:admitted_transport_context))
          end
        end

        assert_equal original, source.reload.attributes
        assert_equal BigDecimal("10"), account.reload.balance
      end
    end
  end

  test "after update failure rolls back account SQL before current balance and transaction publication" do
    with_source do |_item, source, account|
      source.update!(raw_transactions_payload: [ transaction ])
      original = account.attributes
      observed = []
      callback = lambda do |current|
        next unless current.id == account.id && current.cash_balance == BigDecimal("25")
        observed << Account.where(id: account.id).pick(:cash_balance)
        raise IOError, "Simulated balance callback failure"
      end
      Account.set_callback(:update, :after, callback)
      begin
        assert_no_difference [ "Entry.count", "Valuation.count", "Transaction.count" ] do
          assert_raises(IOError) { EnableBankingAccount::Processor.new(source).process }
        end
      ensure
        Account.skip_callback(:update, :after, callback)
      end

      assert_equal [ BigDecimal("25") ], observed
      assert_equal original, account.reload.attributes
      assert EnableBankingAccount::Processor.new(source).process[:success]
      assert_equal BigDecimal("25"), account.reload.balance
      assert_equal 1, account.entries.where(entryable_type: "Transaction").count
    end
  end

  test "failed delegated transaction SQL and merchant creation roll back before a failed result and fresh retry" do
    with_source do |_item, source, account|
      source.update!(raw_transactions_payload: [ transaction ])
      observed = []
      callback = lambda do |current|
        observed << Transaction.exists?(current.id)
        raise IOError, "Simulated transaction callback failure"
      end
      Transaction.set_callback(:create, :after, callback)
      begin
        assert_no_difference [ "Entry.count", "Transaction.count", "Merchant.count" ] do
          result = EnableBankingAccount::Transactions::Processor.new(source).process
          assert_equal false, result[:success]
          assert_equal 1, result[:failed]
        end
      ensure
        Transaction.skip_callback(:create, :after, callback)
      end

      assert_equal [ true ], observed
      assert_empty account.entries
      assert EnableBankingAccount::Transactions::Processor.new(source).process[:success]
      assert_equal 1, account.entries.count
    end
  end

  test "busy financial row refuses publication instead of reporting an ordinary row failure" do
    with_source do |_item, source, account|
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      source.update!(raw_transactions_payload: [ transaction ])
      entered, release = Queue.new, Queue.new
      worker = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          Account.transaction do
            Account.lock.find(account.id)
            entered << true
            release.pop
          end
        end
      end
      Timeout.timeout(5) { entered.pop }

      assert_raises(Fence::Busy) { EnableBankingAccount::Processor.new(source).process }
      assert_raises(Fence::Busy) { EnableBankingAccount::Transactions::Processor.new(source).process }
      assert_empty account.entries
      assert_equal BigDecimal("10"), account.reload.balance
    ensure
      release << true if release
      worker&.join(5)
      worker&.kill if worker&.alive?
      worker&.join
    end
  end

  test "HTTP is refused in an outer row transaction even when the item permit is already held" do
    with_source do |item, source, account|
      client = client_for(source)
      ApplicationRecord.transaction do
        assert_raises(ArgumentError) { EnableBankingItem::Importer.new(item, enable_banking_provider: client).import }
      end
      Access.with_item(item) do
        ApplicationRecord.transaction do
          assert_raises(Fence::InvalidSource) { EnableBankingItem::Importer.new(item, enable_banking_provider: client).import }
        end
      end
      assert_empty client.requests
      assert_empty account.entries
    end
  end

  test "scheduled deletion denies importing processing and progress without rewriting the deletion request" do
    with_source do |item, source, account|
      sync = item.syncs.create!(status_text: "Unchanged")
      item.update!(scheduled_for_deletion: true)
      original = [ item, source, account, sync ].map { |record| record.reload.attributes }
      client = client_for(source)

      assert_raises(Fence::OwnershipChanged) { EnableBankingItem::Importer.new(item, enable_banking_provider: client).import }
      assert_raises(Fence::OwnershipChanged) { EnableBankingAccount::Processor.new(source).process }
      assert_raises(Fence::OwnershipChanged) { EnableBankingItem::Syncer.new(item).perform_sync(sync) }

      assert_empty client.requests
      assert_equal original, [ item, source, account, sync ].map { |record| record.reload.attributes }
    end
  end

  private
    def with_source
      with_provider_encryption do
        merchant_name = @merchant_name = "Enable Banking admission #{SecureRandom.uuid}"
        family = Family.create!(name: "Enable Banking admission", timezone: "UTC")
        item = create_item(family, "Enable Banking")
        remote_id = SecureRandom.uuid
        source = item.enable_banking_accounts.create!(uid: remote_id, account_id: remote_id,
          name: "Checking", currency: "EUR", current_balance: 25, raw_transactions_payload: [])
        account = create_account(family, "Checking")
        AccountProvider.create!(account: account, provider: source)
        yield item, source, account
      ensure
        if family
          ProviderMigrationControl.where(family: family).delete_all
          Sync.where(syncable_type: "EnableBankingItem", syncable_id: family.enable_banking_items.select(:id)).delete_all
          AccountProvider.where(account_id: family.accounts.select(:id)).delete_all
          family.accounts.each(&:destroy!)
          family.enable_banking_items.destroy_all
          family.destroy!
        end
        ProviderMerchant.where(source: "enable_banking", name: merchant_name).delete_all if merchant_name
        @merchant_name = nil
      end
    end

    def create_item(family, name)
      family.enable_banking_items.create!(name: name, country_code: "FI", application_id: SecureRandom.uuid,
        client_certificate: "admission-test-certificate", session_id: SecureRandom.uuid,
        session_expires_at: 1.day.from_now, status: :good)
    end

    def create_account(family, name)
      family.accounts.create!(name: name, balance: 10, cash_balance: 10, currency: "EUR", accountable: Depository.new)
    end

    def transaction(currency: "EUR")
      { "transaction_id" => "transaction-1", "booking_date" => (Date.current - 2).iso8601,
        "transaction_amount" => { "amount" => "12.50", "currency" => currency },
        "credit_debit_indicator" => "DBIT", "status" => "BOOK", "creditor_name" => @merchant_name,
        "remittance_information" => [ "Fixture purchase" ] }
    end

    def client_for(source, currency: "EUR", &on_read)
      Client.new(account_id: source.api_account_id, transaction: transaction(currency: currency), currency: currency,
        before_read: lambda do |phase|
          assert_equal 0, ApplicationRecord.connection.open_transactions, "#{phase} HTTP held a database transaction"
          on_read&.call(phase)
        end)
    end

    def drain_in_another_session(item)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      worker = Thread.new do
        Fence.with_exclusive(item) { :drained }
      rescue Fence::Busy
        :busy
      end
      Timeout.timeout(5) { worker.value }
    ensure
      worker&.kill if worker&.alive?
      worker&.join
    end

    class Client
      attr_reader :requests

      def initialize(account_id:, transaction:, currency:, before_read:)
        @account_id, @transaction, @currency, @before_read = account_id, transaction, currency, before_read
        @requests = []
      end

      def get_session(session_id:)
        raise ArgumentError, "Missing consent" if session_id.blank?
        read(:session)
        { accounts: [ @account_id ] }
      end

      def get_account_balances(account_id:, psu_headers:)
        raise ArgumentError, "Unexpected account" unless account_id == @account_id
        read(:balances)
        { balances: [ { balance_type: "CLBD", balance_amount: { amount: "55.25", currency: @currency },
          credit_debit_indicator: "CRDT" } ] }
      end

      def get_account_transactions(account_id:, date_from:, continuation_key:, transaction_status:, psu_headers:)
        unless account_id == @account_id && date_from.present? && continuation_key.nil? && transaction_status == "BOOK"
          raise ArgumentError, "Unexpected transaction request"
        end
        read(:transactions)
        { transactions: [ @transaction ], continuation_key: nil }
      end

      private
        def read(phase)
          @requests << phase
          @before_read.call(phase)
        end
    end
end
