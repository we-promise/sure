module ProviderAccountLockingTestHelper
  def capture_provider_locks
    locks = []
    subscriber = ->(event) do
      sql = event.payload.fetch(:sql)
      if sql.include?("FOR UPDATE")
        locks << { sql: sql, binds: event.payload.fetch(:binds, []).map(&:value_for_database) }
      end
    end
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
    locks
  end

  def assert_ordered_account_locks(locks, accounts)
    account_locks = locks.select { |lock| lock.fetch(:sql).include?('FROM "accounts"') }
    assert_equal 1, account_locks.size, "Acquire the whole financial account set together"
    query = account_locks.sole
    assert_match(/ORDER BY "accounts"\."id" ASC/, query.fetch(:sql))
    ids = accounts.map(&:id).sort
    assert_equal ids, query.fetch(:binds).select { |value| ids.include?(value) }
    source_locks = locks.select { |lock| lock.fetch(:sql).match?(/FROM "(?:external_accounts|account_providers)"/) }
    assert source_locks.all? { |lock| locks.index(lock) > locks.index(query) }, "Lock financial accounts before source/link rows"
  end
end
