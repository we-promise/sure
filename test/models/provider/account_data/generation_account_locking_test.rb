require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"
require_relative "../../../support/provider_account_locking_test_helper"

class Provider::AccountData::GenerationAccountLockingTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper, ProviderAccountLockingTestHelper

  test "inventory order cannot reverse the common financial account lock order" do
    with_provider_encryption do
      connection, externals, financial = reverse_linked_accounts
      captured = nil
      locks = capture_provider_locks do
        captured = connection.with_lock { Provider::AccountData::GenerationAccounts.new(connection).capture }
      end
      assert_equal financial.map(&:id).reverse, externals.map { |external| captured.fetch(external.external_id).fetch("account_id") }
      assert_ordered_account_locks locks, financial
    end
  end

  test "verification locks the whole financial account set before checking any source binding" do
    with_provider_encryption do
      connection, externals, financial = reverse_linked_accounts
      resolver = Provider::AccountData::GenerationAccounts.new(connection)
      captured = connection.with_lock { resolver.capture }
      yielded = nil
      locks = capture_provider_locks do
        connection.with_lock { resolver.with_verified_bindings(captured.to_a.reverse.to_h) { |values| yielded = values } }
      end
      assert_equal externals.map(&:id).sort, yielded.values.map(&:id).sort
      assert_ordered_account_locks locks, financial
    end
  end

  test "a link already changed before verification does not lock the unexpected financial account" do
    with_provider_encryption do
      connection = create_provider_connection
      external = create_external_account(connection)
      resolver = Provider::AccountData::GenerationAccounts.new(connection)
      captured = connection.with_lock { resolver.capture }
      AccountProvider.create!(account: accounts(:depository), external_account: external)
      locks = capture_provider_locks do
        assert_raises(Provider::AccountData::StaleWriter) do
          connection.with_lock { resolver.with_verified_bindings(captured) { flunk "Changed link cannot publish" } }
        end
      end
      assert_empty locks.select { |lock| lock.fetch(:sql).include?('FROM "accounts"') }
    end
  end

  test "a link reassigned while the account lock plan is acquired cannot expand that plan" do
    with_provider_encryption do
      unexpected, planned = [ accounts(:depository), accounts(:investment) ].sort_by(&:id)
      connection = create_provider_connection
      external = create_external_account(connection, status: "ignored")
      link = AccountProvider.create!(account: planned, external_account: external)
      resolver = Provider::AccountData::GenerationAccounts.new(connection)
      captured = connection.with_lock { resolver.capture }
      # Deterministically interleave a relink after planning but before locking.
      # The replacement sorts before the planned account: adopting it afterwards
      # would acquire financial locks in the opposite order from another writer.
      resolver.define_singleton_method(:lock_accounts) do |ids|
        link.update!(account: unexpected)
        super(ids)
      end
      locks = capture_provider_locks do
        assert_raises(Provider::AccountData::StaleWriter) do
          connection.with_lock { resolver.with_verified_bindings(captured) { flunk "A raced link cannot publish" } }
        end
      end
      assert_ordered_account_locks locks, [ planned ]
      assert locks.select { |lock| lock.fetch(:sql).include?('FROM "accounts"') }.none? { |lock| lock.fetch(:binds).include?(unexpected.id) }
    end
  end

  test "a new link inserted after planning cannot turn a retained source into a financial writer" do
    with_provider_encryption do
      connection = create_provider_connection
      external = create_external_account(connection)
      resolver = Provider::AccountData::GenerationAccounts.new(connection)
      account = accounts(:depository)
      resolver.define_singleton_method(:lock_accounts) do |ids|
        AccountProvider.create!(account: account, external_account: external)
        super(ids)
      end
      locks = capture_provider_locks do
        assert_raises(Provider::AccountData::StaleWriter) { connection.with_lock { resolver.capture } }
      end
      assert_empty locks.select { |lock| lock.fetch(:sql).include?('FROM "accounts"') }
    end
  end

  test "single-account verification yields fresh linkage instead of a previously cached association" do
    with_provider_encryption do
      connection = create_provider_connection
      external = create_external_account(connection)
      assert_nil external.current_account
      link = AccountProvider.create!(account: accounts(:depository), external_account: external)
      Account::SourcePolicy.select!(account: link.account, account_provider: link, resource: "transactions")
      resolver = Provider::AccountData::GenerationAccounts.new(connection)
      captured = connection.with_lock { resolver.capture }.fetch(external.external_id)
      connection.with_lock do
        resolver.with_verified_binding(external, captured) do |locked|
          assert_equal link.account_id, locked.current_account.id
        end
      end
    end
  end

  private
    def reverse_linked_accounts
      connection = create_provider_connection
      financial = [ accounts(:depository), accounts(:investment) ].sort_by(&:id)
      external_ids = Array.new(2) { SecureRandom.uuid }.sort
      externals = financial.reverse.zip(external_ids).map do |account, id|
        external = create_external_account(connection, id: id)
        link = AccountProvider.create!(account: account, external_account: external)
        Account::SourcePolicy.select!(account: account, account_provider: link, resource: "transactions")
        external
      end
      [ connection, externals, financial ]
    end
end
