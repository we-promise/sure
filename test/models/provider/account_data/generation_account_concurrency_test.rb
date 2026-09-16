require "test_helper"
require "timeout"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::GenerationAccountConcurrencyTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  test "overlapping providers wait for the lowest account UUID before either can lock a higher account" do
    skip "Requires PostgreSQL row locks" unless ApplicationRecord.connection.adapter_name == "PostgreSQL"
    skip "Requires three database sessions" if ApplicationRecord.connection_pool.size < 3

    with_provider_encryption do
      financial = [ accounts(:depository), accounts(:investment) ].sort_by(&:id)
      existing_identity_ids = Account::IngestionIdentity.where(id: financial.map(&:id)).pluck(:id)
      connections, links = [], []
      begin
        %w[up plaid].each_with_index do |key, index|
          connection = create_provider_connection(provider_key: key)
          connections << connection
          ids = Array.new(2) { SecureRandom.uuid }.sort
          ordered = index.zero? ? financial : financial.reverse
          ordered.zip(ids).each do |account, id|
            external = create_external_account(connection, id: id)
            link = AccountProvider.create!(account: account, external_account: external)
            links << link
            Account::SourcePolicy.select!(account: account, account_provider: link, resource: "transactions") if index.zero?
          end
        end
        snapshots = connections.to_h do |connection|
          [ connection.id, connection.with_lock { Provider::AccountData::GenerationAccounts.new(connection).capture } ]
        end

        %i[capture verify].each do |operation|
          results = contend(connections, financial, snapshots, operation)
          assert_equal snapshots, results.to_h
        end
      ensure
        Account::SourcePolicy.where(account_provider_id: links.map(&:id)).delete_all
        links.reverse_each(&:destroy!)
        connections.reverse_each { |connection| connection.reload.destroy! }
        Account::IngestionIdentity.where(id: financial.map(&:id) - existing_identity_ids).each(&:destroy!)
      end
    end
  end

  private
    def contend(connections, financial, snapshots, operation)
      workers, pids = [], Queue.new
      begin
        financial.first.with_lock do
          connections.each do |connection|
            connection_id = connection.id
            workers << Thread.new do
              ApplicationRecord.connection_pool.with_connection do |database|
                key_provider = ActiveRecord::Encryption::KeyProvider.new("provider-ingestion-test-key-0001")
                ActiveRecord::Encryption.with_encryption_context(key_provider: key_provider) do
                  current = ProviderConnection.find(connection_id)
                  current.with_lock do
                    database.execute("SET LOCAL lock_timeout = '10s'")
                    database.execute("SET LOCAL statement_timeout = '12s'")
                    pids << database.select_value("SELECT pg_backend_pid()").to_i
                    resolver = Provider::AccountData::GenerationAccounts.new(current)
                    if operation == :capture
                      [ connection_id, resolver.capture ]
                    else
                      resolver.with_verified_bindings(snapshots.fetch(connection_id)) do
                        [ connection_id, snapshots.fetch(connection_id) ]
                      end
                    end
                  end
                end
              end
            end
          end
          worker_pids = Timeout.timeout(5) { Array.new(2) { pids.pop } }
          wait_until_blocked(worker_pids)
          # Both sessions have reached a contended lock. The higher UUID must
          # still be free: a provider following its reverse inventory order
          # would already hold it while waiting for the lowest UUID we own.
          assert_equal financial.last.id, Account.lock("FOR UPDATE NOWAIT").find(financial.last.id).id
        end
        Timeout.timeout(15) { workers.map(&:value) }
      ensure
        # Database timeouts bound failures too; release workers before deleting
        # their fixture-independent source rows or returning to another test.
        workers.each do |worker|
          worker.kill unless worker.join(15)
          worker.join
        end
      end
    end

    def wait_until_blocked(pids)
      database = ApplicationRecord.connection
      Timeout.timeout(5) do
        until pids.all? { |pid| database.select_value("SELECT cardinality(pg_blocking_pids(#{Integer(pid)})) > 0") }
          sleep 0.01
        end
      end
    end
end
