require "test_helper"
require "timeout"
require_relative "../../support/provider_ingestion_test_helper"

class AkahuAccount::PublicationTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false
  Access = AkahuItem::LegacyAccess
  Fence = Access::Fence
  Cleanup = AkahuAccount::PendingCleanup

  setup do
    DebugLogEntry.stubs(:capture)
    Sentry.stubs(:capture_exception)
    Provider::Akahu.expects(:new).never
  end

  test "fresh publication preserves legacy balance and transaction signs without transport" do
    with_source do |_item, source, account|
      source.update!(raw_transactions_payload: [ raw ])
      result = AkahuAccount::Processor.new(source).process
      assert result[:success]
      assert_equal BigDecimal("25"), account.reload.balance
      assert_equal BigDecimal("25"), account.cash_balance
      entry = account.entries.sole
      assert_equal "akahu_transaction-1", entry.external_id
      assert_equal BigDecimal("12.5"), entry.amount
      assert_equal "NZD", entry.currency
      refute entry.transaction.pending?
    end
  end

  test "a processor pins the original source cache and financial link before processing" do
    with_source do |_item, source, account|
      processor = AkahuAccount::Processor.new(source)
      source.update!(raw_transactions_payload: [ raw ])
      assert_raises(Fence::OwnershipChanged) { processor.process }
      assert_equal BigDecimal("10"), account.reload.balance
      assert_empty account.entries

      processor = AkahuEntry::Processor.new(raw, akahu_account: source)
      replacement = create_account(account.family, "Replacement")
      source.account_provider.update!(account: replacement)
      assert_raises(Fence::OwnershipChanged) { processor.process }
      assert_empty account.entries
      assert_empty replacement.entries
    end
  end

  test "financial currency drift and foreign remote identities refuse before any row publication" do
    with_source do |_item, source, account|
      processor = AkahuEntry::Processor.new(raw, akahu_account: source)
      account.update!(currency: "USD")
      assert_raises(Fence::OwnershipChanged) { processor.process }
      [ raw.merge("_account" => "another-account"), raw.except("_account") ].each do |row|
        assert_raises(Fence::OwnershipChanged) { AkahuEntry::Processor.new(row, akahu_account: source.reload).process }
      end
      assert_empty account.entries
    end
  end

  test "quiescing and native ownership refuse every direct financial processor" do
    %w[quiescing active retired].each do |state|
      with_source do |item, source, account|
        source.update!(raw_transactions_payload: [ raw ])
        ProviderMigrationControl.create!(family: item.family, provider_key: "akahu", legacy_type: "AkahuItem",
          legacy_id: item.id, state: state, writer_epoch: state == "quiescing" ? 0 : 1)
        assert_raises(Fence::OwnershipChanged) { AkahuAccount::Processor.new(source).process }
        assert_raises(Fence::OwnershipChanged) { AkahuAccount::Transactions::Processor.new(source).process }
        assert_raises(Fence::OwnershipChanged) { AkahuEntry::Processor.new(raw, akahu_account: source).process }
        assert_equal BigDecimal("10"), account.reload.balance
        assert_empty account.entries
      end
    end
  end

  test "another selected provider blocks both cash and balance publication" do
    with_source do |_item, source, account|
      native = add_native_link(account)
      Account::SourcePolicy.select!(account: account, account_provider: native, resource: "transactions")
      Account::SourcePolicy.select!(account: account, account_provider: native, resource: "balances")
      source.update!(raw_transactions_payload: [ raw ])
      assert_raises(Fence::OwnershipChanged) { AkahuAccount::Processor.new(source).process }
      assert_raises(Fence::OwnershipChanged) { AkahuEntry::Processor.new(raw, akahu_account: source).process }
      assert_equal BigDecimal("10"), account.reload.balance
      assert_empty account.entries
    end
  end

  test "an after update failure rolls back actual balance SQL and permits a fresh retry" do
    with_source do |_item, source, account|
      observed = []
      callback = lambda do |current|
        next unless current.id == account.id
        observed << Account.where(id: account.id).pick(:balance)
        raise IOError, "Simulated balance callback failure"
      end
      Account.set_callback(:update, :after, callback)
      begin
        assert_raises(IOError) { AkahuAccount::Processor.new(source).process }
      ensure
        Account.skip_callback(:update, :after, callback)
      end
      assert_equal [ BigDecimal("25") ], observed
      assert_equal BigDecimal("10"), account.reload.balance
      assert AkahuAccount::Processor.new(source).process[:success]
      assert_equal BigDecimal("25"), account.reload.balance
    end
  end

  test "an after create transaction failure rolls back financial SQL before reporting a failed row" do
    with_source do |_item, source, account|
      source.update!(raw_transactions_payload: [ raw ])
      callback = ->(_transaction) { raise IOError, "Simulated transaction callback failure" }
      Transaction.set_callback(:create, :after, callback)
      begin
        assert_no_difference [ "Entry.count", "Transaction.count" ] do
          result = AkahuAccount::Transactions::Processor.new(source).process
          assert_equal false, result[:success]
          assert_equal 1, result[:failed]
        end
      ensure
        Transaction.skip_callback(:create, :after, callback)
      end
      assert_empty account.entries
      assert AkahuAccount::Transactions::Processor.new(source).process[:success]
      assert_equal 1, account.entries.count
    end
  end

  test "cache only processing never infers permission to delete missing pending rows" do
    with_source do |_item, source, account|
      pending = add_pending(account)
      source.update!(raw_transactions_payload: [ raw ])
      result = AkahuAccount::Transactions::Processor.new(source).process
      assert result[:success]
      assert_equal 0, result[:pruned_pending]
      assert Entry.exists?(pending.id)
    end
  end

  test "a complete committed inventory removes only original absent pending rows" do
    with_source do |_item, source, account|
      absent = add_pending(account)
      observed = add_pending(account, external_id: "akahu_still-pending")
      foreign = add_pending(account, source_key: "plaid")
      manual = add_pending(account, source_key: nil, external_id: nil)
      with_inventory(source, pending_rows: [ raw(id: "still-pending", pending: true) ]) do |receipt|
        newer = add_pending(account)
        result = AkahuAccount::Transactions::Processor.new(source.reload, pending_inventory: receipt).process
        assert result[:success]
        assert_equal 1, result[:pruned_pending]
        refute Entry.exists?(absent.id)
        [ observed, foreign, manual, newer ].each { |entry| assert Entry.exists?(entry.id) }
        assert_equal 0, Cleanup.new(source.reload, receipt: receipt).call
      end
    end
  end

  test "complete idless observations preserve previously allocated pending suffix identities" do
    with_source do |_item, source, account|
      row = raw(pending: true).except("_id")
      base = AkahuEntry::Processor.canonical_external_id(row)
      original = add_pending(account, external_id: base)
      suffix = add_pending(account, external_id: "#{base}_2")
      absent = add_pending(account)
      with_inventory(source, pending_rows: [ row ]) do |receipt|
        assert_equal 1, Cleanup.new(source.reload, receipt: receipt).call
      end
      assert Entry.exists?(original.id)
      assert Entry.exists?(suffix.id)
      refute Entry.exists?(absent.id)
    end
  end

  test "receipts cannot cross permit release or be replaced with caller supplied hashes" do
    with_source do |item, source, account|
      pending = add_pending(account)
      captured = nil
      with_inventory(source) { |receipt| captured = receipt }
      Access.with_item(item) do
        assert_raises(Fence::OwnershipChanged) { Cleanup.new(source.reload, receipt: captured).call }
        assert_raises(Fence::OwnershipChanged) { Cleanup.new(source, receipt: {}).call }
      end
      assert Entry.exists?(pending.id)
    end
  end

  test "cache ABA and credential changes invalidate the receipt even inside its permit" do
    [ :cache, :credentials ].each do |change|
      with_source do |item, source, account|
        pending = add_pending(account)
        with_inventory(source) do |receipt|
          if change == :cache
            source.reload.update!(raw_transactions_payload: [ raw ])
            source.update!(raw_transactions_payload: [])
          else
            item.update!(user_token: "changed-token")
          end
          assert_raises(Fence::OwnershipChanged) { Cleanup.new(source.reload, receipt: receipt).call }
          assert Entry.exists?(pending.id)
        end
        with_inventory(source.reload) { |receipt| assert_equal 1, Cleanup.new(source.reload, receipt: receipt).call }
      end
    end
  end

  test "cloning a receipt cannot remove observed identities or add deletion candidates" do
    with_source do |_item, source, account|
      pending = add_pending(account, external_id: "akahu_observed")
      with_inventory(source, pending_rows: [ raw(id: "observed", pending: true) ]) do |receipt|
        clone = receipt.with(pending_ids: [].freeze, pending_bases: [].freeze)
        assert_raises(Fence::OwnershipChanged) { Cleanup.new(source.reload, receipt: clone).call }
        assert Entry.exists?(pending.id)
        assert_equal 0, Cleanup.new(source.reload, receipt: receipt).call
      end
    end
  end

  test "relinking after receipt capture refuses without deleting either account's entries" do
    with_source do |_item, source, account|
      pending = add_pending(account)
      replacement = create_account(account.family, "Replacement")
      other_pending = add_pending(replacement)
      with_inventory(source) do |receipt|
        source.account_provider.update!(account: replacement)
        assert_raises(Fence::OwnershipChanged) { Cleanup.new(source.reload, receipt: receipt).call }
      end
      assert Entry.exists?(pending.id)
      assert Entry.exists?(other_pending.id)
    end
  end

  test "a changed original candidate cannot be deleted by replaying its old receipt" do
    with_source do |_item, source, account|
      pending = add_pending(account)
      with_inventory(source) do |receipt|
        pending.update_columns(name: "A newer pending observation")
        assert_raises(Fence::OwnershipChanged) { Cleanup.new(source.reload, receipt: receipt).call }
        assert Entry.exists?(pending.id)
      end
    end
  end

  test "protected reconciled and field locked pending entries are retained" do
    with_source do |_item, source, account|
      entries = [ { excluded: true }, { user_modified: true }, { import_locked: true },
        { reconciled_at: Time.current }, { locked_attributes: { "name" => Time.current.iso8601 } } ].map do |attributes|
        add_pending(account).tap { |entry| entry.update!(attributes) }
      end
      entries << add_pending(account).tap { |entry| entry.transaction.update!(locked_attributes: { "category_id" => Time.current.iso8601 }) }
      with_inventory(source) do |receipt|
        newly_protected = entries.first
        newly_protected.update!(user_modified: true)
        assert_equal 0, Cleanup.new(source.reload, receipt: receipt).call
      end
      assert_equal entries.size, Entry.where(id: entries.map(&:id)).count
    end
  end

  test "split and transfer ownership prevent pending destruction and counterpart side effects" do
    with_source do |_item, source, account|
      parent = add_pending(account)
      child = add_pending(account)
      child.update_columns(parent_entry_id: parent.id)
      other = create_account(account.family, "Counterparty")
      outflow = add_pending(account)
      inflow = add_pending(other, amount: -12.5)
      transfer = Transfer.create!(outflow_transaction: outflow.transaction, inflow_transaction: inflow.transaction)
      fee = add_pending(account)
      fee.transaction.update!(transfer_id: transfer.id)
      with_inventory(source) { |receipt| assert_equal 0, Cleanup.new(source.reload, receipt: receipt).call }
      [ parent, child, outflow, inflow, fee ].each { |entry| assert Entry.exists?(entry.id) }
      assert Transfer.exists?(transfer.id)
    end
  end

  test "both live and detached native evidence prevent legacy pending deletion" do
    [ false, true ].each do |detached|
      with_source do |_item, source, account|
        pending = add_pending(account)
        evidence = add_evidence(account, pending, detached: detached)
        original = evidence.attributes
        with_inventory(source) { |receipt| assert_equal 0, Cleanup.new(source.reload, receipt: receipt).call }
        assert Entry.exists?(pending.id)
        assert_equal original, evidence.reload.attributes
      end
    end
  end

  test "an actual destroy callback failure rolls back the whole cleanup and can be retried once" do
    with_source do |_item, source, account|
      entries = [ add_pending(account), add_pending(account) ]
      failed_id = entries.map(&:id).max
      observed = []
      callback = lambda do |entry|
        next unless entry.id == failed_id
        observed << Entry.exists?(entry.id)
        raise IOError, "Simulated pending deletion failure"
      end
      with_inventory(source) do |receipt|
        Entry.set_callback(:destroy, :after, callback)
        begin
          assert_raises(IOError) { Cleanup.new(source.reload, receipt: receipt).call }
        ensure
          Entry.skip_callback(:destroy, :after, callback)
        end
        assert_equal [ false ], observed
        assert_equal 2, Entry.where(id: entries.map(&:id)).count
        assert_equal 2, Cleanup.new(source.reload, receipt: receipt).call
        assert_equal 0, Cleanup.new(source.reload, receipt: receipt).call
      end
    end
  end

  test "a competing transaction row lock refuses cleanup before deleting any financial row" do
    with_source do |_item, source, account|
      pending = add_pending(account)
      with_inventory(source) do |receipt|
        with_locked_row(Transaction, pending.entryable_id) do
          assert_raises(Fence::Busy) { Cleanup.new(source.reload, receipt: receipt).call }
        end
        assert Entry.exists?(pending.id)
        assert_equal 1, Cleanup.new(source.reload, receipt: receipt).call
      end
    end
  end

  test "incomplete financial import cannot consume even a valid complete pending inventory" do
    with_source do |_item, source, account|
      pending = add_pending(account)
      with_inventory(source, posted_rows: [ raw.merge("date" => "invalid-date") ]) do |receipt|
        result = AkahuAccount::Transactions::Processor.new(source.reload, pending_inventory: receipt).process
        assert_equal false, result[:success]
        assert_equal 1, result[:failed]
        assert_equal 0, result[:pruned_pending]
        assert Entry.exists?(pending.id)
      end
    end
  end

  test "pending inventory must exactly describe the accepted pending cache" do
    with_source do |item, source, account|
      pending = add_pending(account)
      Access.with_item(item) do
        Access.with_source_snapshot(source) do |fresh|
          fresh.update!(raw_transactions_payload: [ raw(pending: true) ])
          assert_raises(Fence::OwnershipChanged) do
            Cleanup.capture(source: fresh, pending_rows: [], source_context: Access.source_context(fresh),
              transport_context: Access.transport_context(fresh.akahu_item))
          end
        end
      end
      assert Entry.exists?(pending.id)
    end
  end

  test "missing unsupported and nonfinite posted money fails the row and vetoes pending cleanup" do
    [ nil, {}, "NaN", "Infinity" ].each do |amount|
      with_source do |_item, source, account|
        pending = add_pending(account)
        with_inventory(source, posted_rows: [ raw.merge("amount" => amount) ]) do |receipt|
          result = AkahuAccount::Transactions::Processor.new(source.reload, pending_inventory: receipt).process
          assert_equal false, result[:success]
          assert_equal 1, result[:failed]
          assert_equal 0, result[:pruned_pending]
          assert_equal [ pending.id ], account.entries.pluck(:id)
          assert_equal BigDecimal("12.5"), pending.reload.amount
        end
      end
    end
  end

  test "candidate and response bounds refuse without deleting financial rows" do
    with_source do |_item, source, account|
      entries = [ add_pending(account), add_pending(account) ]
      with_limit(:MAX_CANDIDATES, 1) do
        assert_raises(Fence::OwnershipChanged) { with_inventory(source) { flunk "receipt must not escape" } }
      end
      with_limit(:MAX_RECORDS, 0) do
        assert_raises(Fence::OwnershipChanged) { with_inventory(source.reload, pending_rows: [ raw(pending: true) ]) { flunk } }
      end
      with_limit(:MAX_BYTES, 1) do
        assert_raises(Fence::OwnershipChanged) { with_inventory(source.reload) { flunk } }
      end
      assert_equal 2, Entry.where(id: entries.map(&:id)).count
    end
  end

  test "legitimate balance currency changes require a fresh inventory before pending cleanup" do
    with_source do |_item, source, account|
      pending = add_pending(account)
      source.update!(currency: "USD")
      with_inventory(source) do |receipt|
        assert_raises(Fence::OwnershipChanged) do
          AkahuAccount::Processor.new(source.reload, pending_inventory: receipt).process
        end
      end
      assert_equal "USD", account.reload.currency
      assert_equal BigDecimal("25"), account.balance
      assert Entry.exists?(pending.id)
      with_inventory(source.reload) { |receipt| assert_equal 1, Cleanup.new(source.reload, receipt: receipt).call }
    end
  end

  private
    def raw(id: "transaction-1", pending: false)
      { "_id" => id, "_account" => "account-1", "amount" => "-12.50", "currency" => "NZD",
        "date" => 1.day.ago.getutc.iso8601, "description" => "Purchase", "_pending" => pending }
    end

    def add_pending(account, external_id: "akahu_#{SecureRandom.uuid}", source_key: "akahu", amount: 12.5)
      account.entries.create!(name: "Purchase", external_id: external_id, source: source_key,
        amount: amount, currency: account.currency, date: 1.day.ago.to_date,
        entryable: Transaction.new(extra: { (source_key || "akahu") => { "pending" => true } }))
    end

    def with_inventory(source, pending_rows: [], posted_rows: [])
      Access.with_item(source.akahu_item) do |item|
        source.reload
        transport = Access.transport_context(item)
        receipt = Access.with_source_snapshot(source, expected_context: Access.source_context(source), expected_item_context: transport) do |fresh|
          fresh.update!(raw_transactions_payload: posted_rows + pending_rows)
          Cleanup.capture(source: fresh, pending_rows: pending_rows, source_context: Access.source_context(fresh), transport_context: transport)
        end
        assert_equal 0, ApplicationRecord.connection.open_transactions
        assert receipt.frozen?
        refute_includes receipt.inspect, "Purchase"
        yield receipt
      end
    end

    def add_native_link(account)
      connection = create_provider_connection(family: account.family, provider_key: "mercury", credentials: { "token" => "private-token" })
      external = create_external_account(connection, currency: account.currency)
      AccountProvider.create!(account: account, external_account: external)
    end

    def add_evidence(account, entry, detached:)
      external = add_native_link(account).external_account
      batch = create_provider_batch(external.provider_connection, external_account: external, stream: "transactions",
        scope_key: "account:#{external.id}")
      observation = SourceRecord.create!(family: account.family, account: account, external_account: external,
        ingestion_batch: batch, kind: "transaction", external_id: entry.external_id)
      observation.entry_sources.create!(family: account.family, account: account, entry: detached ? nil : entry,
        entry_identity: entry.id, active: !detached, role: "evidence", match_method: "reviewed_identity")
    end

    def with_limit(name, value)
      original = Cleanup.const_get(name)
      Cleanup.send(:remove_const, name)
      Cleanup.const_set(name, value)
      yield
    ensure
      Cleanup.send(:remove_const, name)
      Cleanup.const_set(name, original)
    end

    def with_locked_row(model, id)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      entered, release = Queue.new, Queue.new
      worker = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          model.transaction do
            model.lock.find(id)
            entered << true
            release.pop
          end
        end
      rescue => error
        entered << error
      end
      admission = Timeout.timeout(5) { entered.pop }
      raise admission if admission.is_a?(Exception)
      yield
    ensure
      release << true if release
      worker&.join(5)
      worker&.kill if worker&.alive?
      worker&.join
    end

    def create_account(family, name)
      family.accounts.create!(name: name, balance: 10, currency: "NZD", accountable: Depository.new)
    end

    def with_source
      with_provider_encryption do
        family = Family.create!(name: "Akahu publication")
        item = family.akahu_items.create!(name: "Akahu", app_token: "original-app-token", user_token: "original-user-token")
        source = item.akahu_accounts.create!(name: "Checking source", account_id: "account-1", currency: "NZD",
          current_balance: 25, raw_transactions_payload: [])
        account = create_account(family, "Checking")
        AccountProvider.create!(account: account, provider: source)
        yield item, source, account
      ensure
        if family&.persisted?
          entries = Entry.where(account_id: family.accounts.select(:id))
          transaction_ids = entries.where(entryable_type: "Transaction").pluck(:entryable_id)
          EntrySource.where(family: family).delete_all
          SourceRecord.where(family: family).delete_all
          IngestionBatch.where(family: family).delete_all
          Account::SourcePolicy.where(family: family).delete_all
          AccountProvider.where(account_id: family.accounts.select(:id)).delete_all
          ProviderMigrationControl.where(family: family).delete_all
          Transfer.where(inflow_transaction_id: transaction_ids).or(Transfer.where(outflow_transaction_id: transaction_ids)).delete_all
          Transaction.where(id: transaction_ids).update_all(transfer_id: nil)
          entries.update_all(parent_entry_id: nil)
          family.accounts.reload.each(&:destroy!)
          ProviderConnection.where(family: family).find_each(&:destroy!)
          Sync.where(syncable_type: "AkahuItem", syncable_id: item.id).delete_all
          item.reload.destroy!
          family.destroy!
        end
      end
    end
end
