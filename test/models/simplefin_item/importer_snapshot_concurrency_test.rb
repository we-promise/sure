require "test_helper"
require "timeout"

class SimplefinItem::ImporterSnapshotConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "an older HTTP request finishing last cannot replace newer holdings" do
    item = SimplefinItem.create!(family: families(:dylan_family), name: "Out of order requests", access_url: "https://example.com/access")
    source = item.simplefin_accounts.create!(name: "Brokerage", account_id: "out-of-order", currency: "USD", account_type: "investment", current_balance: 100)
    payload = { id: source.account_id, name: source.name, currency: "USD", balance: "100" }
    holding = { "id" => "newer-position", "shares" => "2" }
    ready, release = Queue.new, Queue.new
    slow_provider = Object.new
    slow_provider.define_singleton_method(:get_accounts) do |*_, **_options|
      ready << true
      release.pop
      { accounts: [ payload.merge(holdings: []) ] }
    end
    slow = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        importer = SimplefinItem::Importer.new(SimplefinItem.find(item.id), simplefin_provider: slow_provider)
        response = importer.send(:fetch_accounts_data, start_date: nil)
        importer.send(:import_account, response[:accounts].first)
      end
    end
    Timeout.timeout(10) { ready.pop }
    fast_provider = mock
    fast_provider.expects(:get_accounts).returns(accounts: [ payload.merge(holdings: [ holding ]) ])
    importer = SimplefinItem::Importer.new(item, simplefin_provider: fast_provider)
    response = importer.send(:fetch_accounts_data, start_date: nil)
    importer.send(:import_account, response[:accounts].first)
    requested_at = source.reload.holdings_requested_at
    assert_not_nil requested_at
    release << true
    Timeout.timeout(10) { slow.value }

    assert_equal [ holding ], source.reload.raw_holdings_payload
    assert_equal requested_at, source.holdings_requested_at
  ensure
    release << true if release
    slow&.kill if slow&.alive?
    slow&.join
    item&.destroy!
  end

  test "an older balances-only HTTP response cannot replace a newer full snapshot" do
    item = SimplefinItem.create!(family: families(:dylan_family), name: "Overlapping balance requests", access_url: "https://example.com/access")
    source = item.simplefin_accounts.create!(name: "Checking", account_id: "balance-order", currency: "USD", account_type: "depository", current_balance: 100)
    account = accounts(:depository)
    old_link = account.simplefin_account_id
    account.update!(simplefin_account_id: source.id)
    payload = { id: source.account_id, name: "Old name", currency: "USD", balance: "100" }
    ready, release = Queue.new, Queue.new
    slow_provider = Object.new
    slow_provider.define_singleton_method(:get_accounts) do |*_, **_options|
      ready << true
      release.pop
      { accounts: [ payload ] }
    end
    slow = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        SimplefinItem::Importer.new(SimplefinItem.find(item.id), simplefin_provider: slow_provider).import_balances_only
      end
    end
    Timeout.timeout(10) { ready.pop }
    fast_provider = mock
    fast_provider.expects(:get_accounts).returns(accounts: [ payload.merge(name: "New name", balance: "200") ])
    importer = SimplefinItem::Importer.new(item, simplefin_provider: fast_provider)
    response = importer.send(:fetch_accounts_data, start_date: nil)
    importer.send(:import_account, response[:accounts].first)
    account_values = account.reload.attributes.slice("balance", "cash_balance")
    release << true
    Timeout.timeout(10) { slow.value }

    assert_equal "New name", source.reload.name
    assert_equal 200, source.current_balance
    assert_equal account_values, account.reload.attributes.slice("balance", "cash_balance")
  ensure
    release << true if release
    slow&.kill if slow&.alive?
    slow&.join
    account&.update!(simplefin_account_id: old_link)
    item&.destroy!
  end

  test "an overlapping later import wins after an empty snapshot is prepared" do
    item = SimplefinItem.create!(family: families(:dylan_family), name: "Concurrent snapshots", access_url: "https://example.com/access")
    source = item.simplefin_accounts.create!(name: "Brokerage", account_id: "concurrent", currency: "USD", account_type: "investment", current_balance: 100)
    payload = { id: source.account_id, name: source.name, currency: "USD", balance: "100" }
    holding = { "id" => "position", "shares" => "2" }
    ready, release, backend = Queue.new, Queue.new, Queue.new
    first_importer = SimplefinItem::Importer.new(item, simplefin_provider: nil)
    first_importer.stubs(:update_inactive_state).with do |_, _|
      ready << ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()")
      release.pop
      true
    end

    first = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        first_importer.send(:import_account, payload.merge(holdings: []))
      end
    end
    writer_pid = Timeout.timeout(10) { ready.pop }

    second = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        backend << connection.select_value("SELECT pg_backend_pid()")
        importer = SimplefinItem::Importer.new(SimplefinItem.find(item.id), simplefin_provider: nil)
        importer.send(:import_account, payload.merge(holdings: [ holding ]))
      end
    end
    pid = Timeout.timeout(10) { backend.pop }
    Timeout.timeout(10) do
      ActiveRecord::Base.uncached do
        while second.alive?
          break if ActiveRecord::Base.connection.select_value("SELECT #{Integer(writer_pid)} = ANY(pg_blocking_pids(#{Integer(pid)}))")
          sleep 0.01
        end
      end
    end
    release << true
    Timeout.timeout(10) { [ first, second ].each(&:value) }

    assert_equal [ holding ], source.reload.raw_holdings_payload
  ensure
    release << true if release
    [ first, second ].compact.each { |thread| thread.kill if thread.alive? }
    [ first, second ].compact.each(&:join)
    item&.destroy!
  end
end
