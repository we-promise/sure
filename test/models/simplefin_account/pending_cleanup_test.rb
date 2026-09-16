require "test_helper"
require "timeout"
require_relative "../../support/provider_ingestion_test_helper"

class SimplefinAccount::PendingCleanupTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false
  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    DebugLogEntry.stubs(:capture)
  end

  test "only the admitted SimpleFIN source can supply pending and posted identities" do
    with_source do |source, account|
      pending = add_entry(source, account)
      plaid = add_entry(source, account, source_key: "plaid", date: 12.days.ago.to_date, amount: 700)
      add_entry(source, account, pending: false, source_key: "plaid")
      add_entry(source, account, pending: false, source_key: nil, external_id: nil)
      other = Account.create!(family: account.family, name: "Other account", currency: "USD", balance: 80, accountable: Depository.new)
      other_entry = add_entry(source, other, pending: false, cache: false)

      assert_empty run_cleanup(source, account)
      refute pending.reload.excluded?
      refute plaid.reload.excluded?
      refute other_entry.reload.excluded?

      posted = add_entry(source, account, pending: false, name: "Settled purchase")
      outcomes = run_cleanup(source, account)
      assert_equal [ :exact ], outcomes.map { |row| row.fetch(:kind) }
      assert_equal pending.id, outcomes.sole.fetch(:entry_id)
      assert_equal account.id, outcomes.sole.fetch(:account_id)
      assert_equal account.name, outcomes.sole.fetch(:account_name)
      assert_equal pending.name, outcomes.sole.fetch(:pending_name)
      assert_equal posted.name, outcomes.sole.fetch(:posted_name)
      assert pending.reload.excluded?
      refute plaid.reload.excluded?
      assert_equal BigDecimal("100"), pending.amount
      assert_equal BigDecimal("100"), posted.reload.amount
    end
  end

  test "both pending and posted rows require exact current raw cache membership" do
    with_source do |source, account|
      pending = add_entry(source, account, cache: false)
      posted = add_entry(source, account, pending: false, cache: false)
      assert_empty run_cleanup(source, account)
      cache_entry(source, pending, pending: true)
      assert_empty run_cleanup(source, account)
      cache_entry(source, posted, pending: false)
      assert_equal [ :exact ], run_cleanup(source, account).map { |row| row.fetch(:kind) }
      assert pending.reload.excluded?
    end
  end

  test "duplicate cached identities and missing external identities cannot establish cleanup ownership" do
    with_source do |source, account|
      pending = add_entry(source, account, date: 10.days.ago.to_date)
      source.update!(raw_transactions_payload: source.raw_transactions_payload * 2)
      idless = add_entry(source, account, external_id: nil, cache: false, amount: 300, date: pending.date)
      assert_empty run_cleanup(source, account)
      refute pending.reload.excluded?
      refute idless.reload.excluded?
    end
  end

  test "a cache above the record budget reports incomplete cleanup without financial writes" do
    with_source do |source, account|
      pending = add_entry(source, account, date: 10.days.ago.to_date)
      posted = add_entry(source, account, pending: false, date: pending.date + 1)
      DebugLogEntry.expects(:capture).with do |attributes|
        attributes[:provider_key] == "simplefin" && attributes[:family]&.id == account.family_id &&
          attributes.fetch(:metadata).fetch(:simplefin_account_id) == source.id
      end.once
      outcomes = []
      with_cleanup_limit(:MAX_CACHE_RECORDS, 1) do
        assert_equal false, cleanup(source, account).call { |row| outcomes << row }
      end
      assert_equal [ :error, :finished ], outcomes.map { |row| row.fetch(:kind) }
      assert_equal false, outcomes.last.fetch(:success)
      refute pending.reload.excluded?
      refute posted.reload.excluded?
      assert_nil pending.transaction.reload.extra["potential_posted_match"]
      assert_equal BigDecimal("100"), account.reload.balance
    end
  end

  test "a stored cache above the byte budget reports incomplete cleanup without financial writes" do
    with_source do |source, account|
      pending = add_entry(source, account, date: 10.days.ago.to_date)
      stored = SimplefinAccount.find(source.id).read_attribute_before_type_cast(:raw_transactions_payload)
      bytes = stored.is_a?(String) ? stored.bytesize : stored.to_json.bytesize
      assert_operator bytes, :>, 1
      DebugLogEntry.expects(:capture).with do |attributes|
        attributes[:provider_key] == "simplefin" && attributes[:family]&.id == account.family_id &&
          attributes.fetch(:metadata).fetch(:simplefin_account_id) == source.id
      end.once
      outcomes = []
      with_cleanup_limit(:MAX_CACHE_BYTES, bytes - 1) do
        assert_equal false, cleanup(source, account).call { |row| outcomes << row }
      end
      assert_equal [ :error, :finished ], outcomes.map { |row| row.fetch(:kind) }
      assert_equal false, outcomes.last.fetch(:success)
      refute pending.reload.excluded?
      assert_nil pending.transaction.reload.extra["potential_posted_match"]
      assert_equal BigDecimal("100"), account.reload.balance
    end
  end

  test "raw cache financial identity drift cannot authorize exclusion" do
    %w[amount currency posted pending].each do |field|
      with_source do |source, account|
        pending = add_entry(source, account)
        add_entry(source, account, pending: false)
        cache = source.reload.raw_transactions_payload.deep_dup
        cache.first[field] = { "amount" => "-999", "currency" => "EUR", "posted" => Date.current.to_s, "pending" => false }.fetch(field)
        source.update!(raw_transactions_payload: cache)
        assert_empty run_cleanup(source, account), field
        refute pending.reload.excluded?, field
      end
    end
  end

  test "ambiguous exact candidates and reverse pending matches are not automatically excluded" do
    [ :two_posted, :two_pending ].each do |ambiguity|
      with_source do |source, account|
        pending = add_entry(source, account)
        add_entry(source, account, pending: false, name: "Unrelated settled name")
        sibling = add_entry(source, account, pending: ambiguity == :two_pending, name: "Another unmatched name")
        assert_empty run_cleanup(source, account), ambiguity
        refute pending.reload.excluded?
        refute sibling.reload.excluded?
      end
    end
  end

  test "protected reconciled and field locked pending entries remain untouched" do
    protections = [
      { excluded: true }, { user_modified: true }, { import_locked: true },
      { reconciled_at: Time.current }, { locked_attributes: { "name" => Time.current.iso8601 } }
    ]
    protections.each do |attributes|
      with_source do |source, account|
        pending = add_entry(source, account, date: 12.days.ago.to_date)
        add_entry(source, account, pending: false, date: 10.days.ago.to_date)
        pending.update!(attributes)
        before = pending.reload.attributes
        assert_empty run_cleanup(source, account), attributes.inspect
        assert_equal before, pending.reload.attributes
      end
    end
    with_source do |source, account|
      pending = add_entry(source, account, date: 12.days.ago.to_date)
      pending.transaction.update!(locked_attributes: { "category_id" => Time.current.iso8601 })
      before = pending.transaction.reload.attributes
      assert_empty run_cleanup(source, account)
      refute pending.reload.excluded?
      assert_equal before, pending.transaction.reload.attributes
    end
  end

  test "excluded and protected posted entries are not matching candidates" do
    [ { excluded: true }, { user_modified: true }, { reconciled_at: Time.current } ].each do |attributes|
      with_source do |source, account|
        pending = add_entry(source, account)
        add_entry(source, account, pending: false).update!(attributes)
        assert_empty run_cleanup(source, account)
        refute pending.reload.excluded?
      end
    end
  end

  test "split and transfer participants are not stale cleanup targets" do
    with_source do |source, account|
      parent = add_entry(source, account, date: 12.days.ago.to_date, amount: 200)
      child = add_entry(source, account, date: parent.date, amount: 100)
      child.update!(parent_entry: parent)
      outflow = add_entry(source, account, date: 12.days.ago.to_date, amount: 300)
      other = Account.create!(family: account.family, name: "Transfer target", currency: "USD", balance: 20, accountable: Depository.new)
      inflow = add_entry(source, other, pending: false, amount: -300, date: outflow.date, cache: false)
      transfer = Transfer.create!(inflow_transaction: inflow.transaction, outflow_transaction: outflow.transaction)
      assert_empty run_cleanup(source, account)
      [ parent, child, outflow, inflow ].each { |entry| refute entry.reload.excluded? }
      assert Transfer.exists?(transfer.id)
    end
  end

  test "fuzzy suggestions preserve metadata use the same sign and are counted only once" do
    with_source do |source, account|
      pending = add_entry(source, account, name: "Cafe, Morning Coffee pending")
      pending.transaction.update!(extra: pending.transaction.extra.merge("retained_note" => "Keep this"))
      posted = add_entry(source, account, pending: false, amount: 120, name: "CAFE Morning Coffee booked")
      outcomes = run_cleanup(source, account)
      assert_equal [ :fuzzy_suggestion ], outcomes.map { |row| row.fetch(:kind) }
      suggestion = pending.transaction.reload.extra.fetch("potential_posted_match")
      assert_equal posted.id, suggestion.fetch("entry_id")
      assert_equal "Keep this", pending.transaction.extra.fetch("retained_note")
      refute pending.reload.excluded?
      assert_empty run_cleanup(source, account)
      assert_equal suggestion, pending.transaction.reload.extra.fetch("potential_posted_match")
    end
    with_source do |source, account|
      pending = add_entry(source, account, name: "Cafe Morning Coffee")
      add_entry(source, account, pending: false, amount: -120, name: pending.name)
      assert_empty run_cleanup(source, account)
      assert_nil pending.transaction.reload.extra["potential_posted_match"]
    end
  end

  test "fuzzy matches honor the three day and twenty five percent bounds" do
    [ { amount: 126 }, { amount: 120, date: Date.current + 2.days } ].each do |attributes|
      with_source do |source, account|
        pending = add_entry(source, account, name: "Cafe Morning Coffee")
        add_entry(source, account, pending: false, name: pending.name, **attributes)
        assert_empty run_cleanup(source, account)
        assert_nil pending.transaction.reload.extra["potential_posted_match"]
      end
    end
  end

  test "stale cleanup uses a strict eight day boundary and emits only persisted exclusions" do
    with_source do |source, account|
      stale = add_entry(source, account, amount: 90, date: 9.days.ago.to_date)
      boundary = add_entry(source, account, amount: 200, date: 8.days.ago.to_date)
      outcomes = run_cleanup(source, account)
      assert_equal [ :stale ], outcomes.map { |row| row.fetch(:kind) }
      assert_equal stale.id, outcomes.sole.fetch(:entry_id)
      assert stale.reload.excluded?
      refute boundary.reload.excluded?
      assert_empty run_cleanup(source, account)
    end
  end

  test "actual after update failures roll back issued SQL and a fresh call counts the retry once" do
    [ :exact, :fuzzy_suggestion ].each do |kind|
      with_source do |source, account|
        pending = add_entry(source, account, name: "Cafe Morning Coffee")
        add_entry(source, account, pending: false, amount: kind == :exact ? 100 : 120, name: pending.name)
        model = kind == :exact ? Entry : Transaction
        record_id = kind == :exact ? pending.id : pending.entryable_id
        observed = []
        failed = lambda do |record|
          if record.id == record_id
            observed << (kind == :exact ? Entry.find(record_id).excluded? : Transaction.find(record_id).extra.key?("potential_posted_match"))
            raise IOError, "Private callback payload must not appear in an outcome"
          end
        end
        DebugLogEntry.expects(:capture).with do |attributes|
          attributes[:provider_key] == "simplefin" &&
            attributes[:family]&.id == account.family_id &&
            attributes.fetch(:metadata).fetch(:entry_id) == pending.id &&
            attributes.fetch(:metadata).fetch(:error_class) == "IOError" &&
            !attributes.inspect.include?("Private callback payload")
        end.once
        model.set_callback(:update, :after, failed)
        begin
          errors = run_cleanup(source, account, expected: false)
          assert_equal [ :error ], errors.map { |row| row.fetch(:kind) }
          refute_includes errors.inspect, "Private callback payload"
        ensure
          model.skip_callback(:update, :after, failed)
        end
        assert_equal [ true ], observed
        refute pending.reload.excluded?
        assert_nil pending.transaction.reload.extra["potential_posted_match"]
        assert_equal [ kind ], run_cleanup(source, account).map { |row| row.fetch(:kind) }
        assert_empty run_cleanup(source, account)
      end
    end
  end

  test "one failed entry does not roll back another completed entry" do
    with_source do |source, account|
      failed_entry = add_entry(source, account, date: 10.days.ago.to_date, amount: 100)
      successful = add_entry(source, account, date: 10.days.ago.to_date, amount: 300)
      failed = ->(entry) { raise IOError, "Callback failed" if entry.id == failed_entry.id }
      Entry.set_callback(:update, :after, failed)
      begin
        outcomes = run_cleanup(source, account, expected: false)
      ensure
        Entry.skip_callback(:update, :after, failed)
      end
      assert_equal [ :error, :stale ], outcomes.map { |row| row.fetch(:kind) }.sort
      refute failed_entry.reload.excluded?
      assert successful.reload.excluded?
      assert_equal [ failed_entry.id ], run_cleanup(source, account).map { |row| row.fetch(:entry_id) }
    end
  end

  test "an admitted outer rollback discards pending writes and all outcome callbacks" do
    with_source do |source, account|
      pending = add_entry(source, account, date: 10.days.ago.to_date)
      outcomes = []
      SimplefinItem::LegacyAccess.with_account(source) do |_admitted|
        Account.transaction do
          assert cleanup(source, account).call { |row| outcomes << row }
          assert pending.reload.excluded?
          assert_empty outcomes
          raise ActiveRecord::Rollback
        end
      end
      refute pending.reload.excluded?
      assert_empty outcomes
      assert_equal [ :stale ], run_cleanup(source, account).map { |row| row.fetch(:kind) }
    end
  end

  test "an admitted outer commit publishes successful outcomes only after financial changes commit" do
    with_source do |source, account|
      pending = add_entry(source, account, date: 10.days.ago.to_date)
      outcomes = []
      SimplefinItem::LegacyAccess.with_account(source) do |_admitted|
        Account.transaction do
          assert cleanup(source, account).call { |row|
            assert_equal 0, ApplicationRecord.connection.open_transactions
            assert pending.reload.excluded?
            outcomes << row
          }
          assert pending.reload.excluded?
          assert_empty outcomes
        end
      end
      assert_equal [ :stale, :unmatched, :finished ], outcomes.map { |row| row.fetch(:kind) }
      assert_equal true, outcomes.last.fetch(:success)
      assert pending.reload.excluded?
    end
  end

  test "relinking before publication rejects without touching either financial account" do
    with_source do |source, account|
      pending = add_entry(source, account, date: 10.days.ago.to_date)
      other = Account.create!(family: account.family, name: "Replacement", currency: "USD", balance: 20, accountable: Depository.new)
      original = SimplefinItem::LegacyAccess.method(:with_publication)
      changed = lambda do |selected, expected_account:, &block|
        AccountProvider.find_by!(provider: source).update!(account: other)
        original.call(selected, expected_account: expected_account, &block)
      end
      outcomes = []
      SimplefinItem::LegacyAccess.stub(:with_publication, changed) do
        assert_raises(Fence::OwnershipChanged) { cleanup(source, account).call { |row| outcomes << row } }
      end
      assert_empty outcomes
      refute pending.reload.excluded?
      assert_empty other.entries
    end
  end

  test "a source reparented to a foreign family cannot acquire a wider permit" do
    with_source do |source, account|
      pending = add_entry(source, account, date: 10.days.ago.to_date)
      original_item = source.simplefin_item
      foreign_family = Family.create!(name: "Foreign pending cleanup")
      foreign_item = SimplefinItem.create!(family: foreign_family, name: "Foreign source", access_url: "https://example.com/foreign")
      SimplefinAccount.where(id: source.id).update_all(simplefin_item_id: foreign_item.id)
      assert_raises(Fence::OwnershipChanged) { cleanup(source, account).call }
      refute pending.reload.excluded?
    ensure
      SimplefinAccount.where(id: source&.id).update_all(simplefin_item_id: original_item.id) if original_item
      foreign_item&.destroy!
      foreign_family&.destroy!
    end
  end

  test "entry and transaction locks in another database session defer without outcomes" do
    [ Entry, Transaction ].each do |model|
      with_source do |source, account|
        pending = add_entry(source, account, date: 10.days.ago.to_date)
        record_id = model == Entry ? pending.id : pending.entryable_id
        with_locked_row(model, record_id) do
          outcomes = []
          assert_raises(Fence::Busy) { cleanup(source, account).call { |row| outcomes << row } }
          assert_empty outcomes
          refute pending.reload.excluded?
        end
      end
    end
  end

  test "a locked posted candidate also defers instead of acting on a stale match" do
    [ Entry, Transaction ].each do |model|
      with_source do |source, account|
        pending = add_entry(source, account)
        posted = add_entry(source, account, pending: false)
        record_id = model == Entry ? posted.id : posted.entryable_id
        with_locked_row(model, record_id) do
          outcomes = []
          assert_raises(Fence::Busy) { cleanup(source, account).call { |row| outcomes << row } }
          assert_empty outcomes
          refute pending.reload.excluded?
        end
      end
    end
  end

  test "quiescing or native ownership denies all pending cleanup" do
    with_source do |source, account|
      pending = add_entry(source, account, date: 10.days.ago.to_date)
      control = ProviderMigrationControl.create!(family: account.family, provider_key: "simplefin",
        legacy_type: "SimplefinItem", legacy_id: source.simplefin_item_id)
      %w[quiescing active].each do |state|
        control.update!(state: state)
        assert_raises(Fence::OwnershipChanged) { cleanup(source, account).call }
        refute pending.reload.excluded?
      end
    end
  end

  test "a cash policy for another source denies writes but the selected legacy link permits them" do
    %w[transactions activities].each do |resource|
      with_source do |source, account|
        pending = add_entry(source, account, date: 10.days.ago.to_date)
        foreign_link = add_native_link(account)
        Account::SourcePolicy.select!(account: account, account_provider: foreign_link, resource: resource)
        assert_raises(Fence::OwnershipChanged) { cleanup(source, account).call }
        refute pending.reload.excluded?

        own_link = AccountProvider.find_by!(provider: source)
        Account::SourcePolicy.select!(account: account, account_provider: own_link, resource: resource)
        assert_equal [ :stale ], run_cleanup(source, account).map { |row| row.fetch(:kind) }
        assert pending.reload.excluded?
      end
    end
  end

  test "retained entry evidence protects both live entries and detached identities" do
    [ false, true ].each do |detached|
      with_source do |source, account|
        pending = add_entry(source, account, date: 10.days.ago.to_date)
        evidence = add_evidence(account, pending, detached: detached)
        before = evidence.attributes
        assert_empty run_cleanup(source, account)
        refute pending.reload.excluded?
        assert_equal before, evidence.reload.attributes
      end
    end
  end

  test "a posted entry with retained evidence is not a heuristic matching candidate" do
    with_source do |source, account|
      pending = add_entry(source, account)
      posted = add_entry(source, account, pending: false)
      add_evidence(account, posted, detached: true)
      assert_empty run_cleanup(source, account)
      refute pending.reload.excluded?
    end
  end

  private
    def with_cleanup_limit(name, value)
      command = SimplefinAccount::PendingCleanup
      original = command.const_get(name)
      command.send(:remove_const, name)
      command.const_set(name, value)
      yield
    ensure
      command.send(:remove_const, name)
      command.const_set(name, original)
    end

    def cleanup(source, account)
      SimplefinAccount::PendingCleanup.new(source, expected_account: account)
    end

    def run_cleanup(source, account, expected: true)
      outcomes = []
      summaries = []
      finished = []
      result = cleanup(source, account).call do |outcome|
        # These are real nontransactional callers: a released savepoint inside
        # an uncommitted publication transaction must not publish a counter.
        assert_equal 0, ApplicationRecord.connection.open_transactions
        if outcome.fetch(:kind) == :finished
          finished << outcome
          next
        elsif outcome.fetch(:kind) == :unmatched
          assert_equal account.id, outcome.fetch(:account_id)
          assert_kind_of Integer, outcome.fetch(:count)
          summaries << outcome
          next
        elsif %i[exact stale].include?(outcome.fetch(:kind))
          assert Entry.find(outcome.fetch(:entry_id)).excluded?
        elsif outcome.fetch(:kind) == :fuzzy_suggestion
          assert Entry.find(outcome.fetch(:entry_id)).transaction.extra["potential_posted_match"].present?
        end
        outcomes << outcome
      end
      assert_equal expected, result
      assert_equal 1, summaries.size
      assert_equal 1, finished.size
      assert_equal expected, finished.sole.fetch(:success)
      outcomes
    end

    def add_entry(source, account, pending: true, amount: 100, date: 2.days.ago.to_date,
      name: "Purchase", source_key: "simplefin", external_id: "simplefin_#{SecureRandom.uuid}", cache: true)
      amount = BigDecimal(amount.to_s)
      entry = account.entries.create!(source: source_key, external_id: external_id, name: name,
        amount: amount, currency: "USD", date: date,
        entryable: Transaction.new(extra: { (source_key || "simplefin") => { "pending" => pending } }))
      cache_entry(source, entry, pending: pending) if cache && source_key == "simplefin"
      entry
    end

    def cache_entry(source, entry, pending:)
      raw = { "id" => entry.external_id.delete_prefix("simplefin_"), "amount" => (-entry.amount).to_s("F"),
        "currency" => entry.currency, "posted" => entry.date.iso8601, "transacted_at" => entry.date.iso8601,
        "pending" => pending, "description" => entry.name }
      source.update!(raw_transactions_payload: source.reload.raw_transactions_payload + [ raw ])
    end

    def add_native_link(account)
      connection = create_provider_connection(family: account.family)
      external = create_external_account(connection)
      AccountProvider.create!(account: account, external_account: external)
    end

    def add_evidence(account, entry, detached:)
      link = add_native_link(account)
      external = link.external_account
      batch = create_provider_batch(external.provider_connection, external_account: external, stream: "transactions",
        scope_key: "account:#{external.id}")
      observation = SourceRecord.create!(family: account.family, account: account, external_account: external,
        ingestion_batch: batch, kind: "transaction", external_id: entry.external_id)
      observation.entry_sources.create!(family: account.family, account: account,
        entry: detached ? nil : entry, entry_identity: entry.id, active: !detached,
        role: "evidence", match_method: "reviewed_identity")
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

    def with_source
      with_provider_encryption do
        family = Family.create!(name: "SimpleFIN pending cleanup")
        item = SimplefinItem.create!(family: family, name: "SimpleFIN", access_url: "https://example.com/access")
        source = item.simplefin_accounts.create!(name: "Checking source", account_id: SecureRandom.uuid,
          currency: "USD", account_type: "checking", current_balance: 100, raw_transactions_payload: [])
        account = Account.create!(family: family, name: "Checking", currency: "USD", balance: 100, accountable: Depository.new)
        AccountProvider.create!(account: account, provider: source)
        yield source, account
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
          entries.update_all(parent_entry_id: nil)
          family.accounts.reload.each(&:destroy!)
          ProviderConnection.where(family: family).find_each(&:destroy!)
          item&.reload&.destroy!
          family.destroy!
        end
      end
    end
end
