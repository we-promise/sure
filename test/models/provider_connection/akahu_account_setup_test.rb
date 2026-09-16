require "test_helper"
require_relative "../../support/akahu_native_management_test_helper"

class ProviderConnection::AkahuAccountSetupTest < ActiveSupport::TestCase
  include AkahuNativeManagementTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  Setup = ProviderConnection::AccountSetup
  Adapter = Provider::AccountData::Akahu

  setup do
    clear_enqueued_jobs
    DebugLogEntry.stubs(:capture)
    Adapter.stubs(:native_ready?).returns(true)
    Account.any_instance.stubs(:sync_later)
  end

  teardown { clear_enqueued_jobs }

  test "native setup preserves Akahu subtype suggestions and explicitly entered signed balances" do
    [ [ "CHECKING", "Depository", "checking", "12.34" ], [ "SAVINGS", "Depository", "savings", "23.45" ],
      [ "TERMDEPOSIT", "Depository", "cd", "34.56" ], [ "CREDITCARD", "CreditCard", "credit_card", "-45.6789" ],
      [ "LOAN", "Loan", nil, "-56.78" ], [ "KIWISAVER", "Investment", "retirement", "67.89" ],
      [ "INVESTMENT", "Investment", nil, "78.90" ] ].each do |remote_type, type, subtype, balance|
      with_akahu_connection do |connection, actor|
        external = create_external_account(connection, currency: "NZD", account_type: remote_type, current_balance: 999)
        command = Setup.new(connection: connection, actor: actor)
        form = command.form(external_account_id: external.id)
        assert_equal %w[Depository CreditCard Loan Investment], form.account_types
        Provider::Akahu.expects(:new).never
        result = nil

        assert_enqueued_with(job: SyncJob) do
          result = command.apply!(token: form.token, attributes: values("accountable_type" => type, "balance" => balance))
        end

        assert_equal [ actor.id, actor.family_id, "Chosen account", "NZD", type ],
          result.account.attributes.values_at("owner_id", "family_id", "name", "currency", "accountable_type")
        assert_equal subtype, result.account.accountable.subtype
        assert_equal BigDecimal(balance), result.account.balance
        assert_equal(type == "Investment" ? BigDecimal("0") : BigDecimal(balance), result.account.cash_balance)
        assert_equal external.id, result.account_provider.external_account_id
        assert_equal connection.id, result.sync.syncable_id
        assert_equal %w[balances transactions], Account::SourcePolicy.active.where(account: result.account).order(:resource).pluck(:resource)
        assert Account::SourcePolicy.active.where(account: result.account).all? { |policy| Account::SourcePolicy::Binding.verify_live!(policy: policy) }
      end
    end
  end

  test "a user type override does not inherit a different accountable type's subtype" do
    with_akahu_connection do |connection, actor|
      external = create_external_account(connection, currency: "NZD", account_type: "KIWISAVER")
      command = Setup.new(connection: connection, actor: actor)

      result = command.apply!(token: command.form(external_account_id: external.id).token, attributes: values)

      assert_equal "Depository", result.account.accountable_type
      assert_nil result.account.accountable.subtype
      assert_equal BigDecimal("12.34"), result.account.cash_balance
    end
  end

  test "existing financial account subtype cash and entries are not setup defaults" do
    with_akahu_connection do |connection, actor|
      external = create_external_account(connection, currency: "NZD", account_type: "KIWISAVER")
      account = actor.family.accounts.create!(owner: actor, name: "Existing investment", currency: "NZD",
        balance: 100, cash_balance: 37, accountable: Investment.new(subtype: "brokerage"))
      entry = account.entries.create!(name: "Reviewed", amount: 7, currency: "NZD", date: Date.current,
        user_modified: true, import_locked: true, entryable: Transaction.new)
      original = [ account.reload.attributes.except("updated_at"), account.accountable.attributes, entry.reload.attributes ]
      command = Setup.new(connection: connection, actor: actor)

      assert_no_difference [ "Account.count", "Entry.count", "Investment.count" ] do
        result = command.apply!(token: command.form(external_account_id: external.id, account_id: account.id).token, attributes: {})
        assert_equal account.id, result.account.id
      end

      assert_equal original, [ account.reload.attributes.except("updated_at"), account.accountable.reload.attributes, entry.reload.attributes ]
    end
  end

  test "the defaults hook receives deeply immutable nonsecret inputs and cannot override user fields" do
    with_akahu_connection do |connection, actor|
      external = create_external_account(connection, currency: "NZD", account_type: "SAVINGS", metadata: { "nested" => [ "source" ] },
        sensitive_details: { "account_number" => "private-number" })
      command = Setup.new(connection: connection, actor: actor)
      original = Adapter.method(:account_setup_defaults)
      inspected = []
      hook = lambda do |account:, accountable_type:|
        assert account.frozen?
        assert account.fetch("metadata").frozen?
        assert account.dig("metadata", "nested").frozen?
        assert account.dig("metadata", "nested", 0).frozen?
        assert accountable_type.frozen?
        assert_equal %w[account_type currency metadata], account.keys.sort
        inspected << accountable_type
        original.call(account: account, accountable_type: accountable_type)
      end
      Adapter.stub(:account_setup_defaults, hook) { command.form(external_account_id: external.id) }
      assert_equal Adapter.account_setup_types, inspected

      [ { "balance" => "0" }, { "currency" => "USD" }, { "subtype" => "retirement" },
        { "cash_balance" => "NaN" }, { "cash_balance" => 0 } ].each do |invalid|
        Adapter.stub(:account_setup_defaults, invalid) do
          assert_raises(Provider::AccountData::UnsupportedCapability) { command.form(external_account_id: external.id) }
        end
      end
      assert_nil external.reload.current_account
      assert_empty connection.syncs
    end
  end

  test "changed adapter defaults and source types invalidate previously reviewed forms" do
    [ :defaults, :source ].each do |change|
      with_akahu_connection do |connection, actor|
        external = create_external_account(connection, currency: "NZD", account_type: "CHECKING")
        command = Setup.new(connection: connection, actor: actor)
        token = command.form(external_account_id: external.id).token
        apply = lambda do
          assert_no_difference [ "Account.count", "AccountProvider.count", "Account::SourcePolicy.count", "Sync.count" ] do
            assert_raises(Setup::Conflict) { command.apply!(token: token, attributes: values) }
          end
        end
        if change == :defaults
          original = Adapter.method(:account_setup_defaults)
          hook = ->(account:, accountable_type:) do
            accountable_type == "Depository" ? { "subtype" => "savings" } : original.call(account: account, accountable_type: accountable_type)
          end
          Adapter.stub(:account_setup_defaults, hook, &apply)
        else
          external.update!(account_type: "SAVINGS")
          apply.call
        end
        assert_nil external.reload.current_account
      end
    end
  end

  test "failure after policy creation rolls back new financial data link policies and Sync" do
    with_akahu_connection do |connection, actor|
      external = create_external_account(connection, currency: "NZD", account_type: "KIWISAVER")
      command = Setup.new(connection: connection, actor: actor)
      token = command.form(external_account_id: external.id).token
      Provider::AccountData::RetainedTransactions.any_instance.stubs(:call).raises(IOError, "Controlled replay failure")

      assert_no_enqueued_jobs do
        assert_no_difference [ "Account.count", "Investment.count", "Entry.count", "AccountProvider.count", "Account::SourcePolicy.count", "Sync.count" ] do
          assert_raises(IOError) { command.apply!(token: token, attributes: values("accountable_type" => "Investment")) }
        end
      end
      assert_nil external.reload.current_account
    end
  end

  test "queue failure retries the original investment account policies and Sync without reapplying defaults" do
    with_akahu_connection do |connection, actor|
      external = create_external_account(connection, currency: "NZD", account_type: "KIWISAVER")
      command = Setup.new(connection: connection, actor: actor)
      token = command.form(external_account_id: external.id).token
      attributes = values("accountable_type" => "Investment", "balance" => "123.4567")
      assert_raises(IOError) do
        SyncJob.stub(:perform_later, ->(*) { raise IOError, "Queue unavailable" }) { command.apply!(token: token, attributes: attributes) }
      end
      account = external.reload.current_account
      link = external.account_provider
      sync = connection.syncs.sole
      original = [ account.reload.attributes, account.accountable.attributes, Account::SourcePolicy.where(account: account).order(:id).map(&:attributes) ]
      Adapter.expects(:account_setup_defaults).never
      result = nil

      assert_no_difference [ "Account.count", "AccountProvider.count", "Account::SourcePolicy.count", "Sync.count" ] do
        assert_enqueued_with(job: SyncJob, args: [ sync ]) { result = command.apply!(token: token, attributes: attributes) }
      end

      assert_equal [ account.id, link.id, sync.id ], [ result.account.id, result.account_provider.id, result.sync.id ]
      assert_equal original, [ account.reload.attributes, account.accountable.reload.attributes, Account::SourcePolicy.where(account: account).order(:id).map(&:attributes) ]
      assert_equal BigDecimal("123.4567"), account.balance
      assert_equal BigDecimal("0"), account.cash_balance
      assert_raises(Setup::Conflict) { command.apply!(token: token, attributes: attributes.merge("balance" => "999")) }
    end
  end

  test "copied never-linked Akahu empty caches remain original evidence after native setup" do
    [ nil, [] ].each do |rows|
      with_copied_unlinked_akahu(rows: rows) do |connection, actor, external, source, mapping|
        original = [ source.reload.attributes, mapping.reload.attributes, akahu_archive_snapshot(connection) ]
        command = Setup.new(connection: connection, actor: actor)

        result = command.apply!(token: command.form(external_account_id: external.id).token,
          attributes: values("accountable_type" => "Investment"))

        assert_equal original, [ source.reload.attributes, mapping.reload.attributes, akahu_archive_snapshot(connection) ]
        assert_equal result.account.id, external.reload.current_account.id
        assert_equal "retirement", result.account.accountable.subtype
        assert_equal BigDecimal("0"), result.account.cash_balance
        Account::SourcePolicy.active.where(account: result.account).each do |policy|
          assert_equal external.id, policy.source_binding.fetch("external_account_id")
          assert_nil policy.source_binding.fetch("legacy_account_id")
          assert Account::SourcePolicy::Binding.verify_live!(policy: policy)
        end
      end
    end
  end

  test "copied unlinked cached transactions require disposition before cutover or setup" do
    rows = [ { "_id" => "unprocessed", "_account" => "native-setup-akahu", "amount" => "-12.34",
      "currency" => "NZD", "date" => "2020-01-02", "description" => "Unprocessed", "type" => "DEBIT" } ]
    with_copied_unlinked_akahu(rows: rows, activate: false) do |connection, actor, external, source, mapping|
      original = [ source.reload.attributes, mapping.reload.attributes, akahu_archive_snapshot(connection) ]
      assert_no_difference [ "Account.count", "AccountProvider.count", "Account::SourcePolicy.count", "Sync.count" ] do
        assert_raises(Provider::AccountData::Akahu::CutoverHistory::Conflict) do
          Provider::AccountData::MigrationCutover.new(provider_key: "akahu", legacy_item_id: source.akahu_item_id,
            family: actor.family, page_size: 1).call
        end
        assert_raises(Setup::Conflict) { Setup.new(connection: connection, actor: actor).form(external_account_id: external.id) }
      end
      assert_equal original, [ source.reload.attributes, mapping.reload.attributes, akahu_archive_snapshot(connection) ]
      assert_nil external.reload.current_account
    end
  end

  test "a copied Akahu source cannot bypass its original binding by losing its archive mapping" do
    with_copied_unlinked_akahu do |connection, actor, external, _source, mapping|
      ProviderMigrationAccountBinding.where(provider_migration_mapping_id: mapping.id).delete_all
      mapping.delete

      assert_no_difference [ "Account.count", "AccountProvider.count", "Account::SourcePolicy.count", "Sync.count" ] do
        assert_raises(Setup::Conflict) { Setup.new(connection: connection, actor: actor).form(external_account_id: external.id) }
      end
      assert_nil external.reload.current_account
    end
  end

  private
    def values(changes = {})
      { "name" => "Chosen account", "accountable_type" => "Depository", "currency" => "NZD", "balance" => "12.34" }.merge(changes)
    end
end
