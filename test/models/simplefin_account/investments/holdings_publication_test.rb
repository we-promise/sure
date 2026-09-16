require "test_helper"
require "timeout"
require_relative "../../../support/provider_ingestion_test_helper"

class SimplefinAccount::Investments::HoldingsPublicationTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  Fence = Provider::AccountData::LegacyWriterFence

  test "security lookup precedes the locked publication and preserves holding values and identity" do
    with_source do |_item, source, account, link, security|
      observed_transactions = []
      before_save = lambda do |holding|
        next unless holding.account_id == account.id
        observed_transactions << ApplicationRecord.connection.open_transactions
      end
      Holding.set_callback(:save, :before, before_save)
      resolve_with(security) do
        assert_equal 0, ApplicationRecord.connection.open_transactions
      end

      SimplefinAccount::Investments::HoldingsProcessor.new(source).process

      holding = account.holdings.find_by!(external_id: "simplefin_current")
      assert_equal BigDecimal("2.5"), holding.qty
      assert_equal BigDecimal("250"), holding.amount
      assert_equal BigDecimal("100"), holding.price
      assert_equal BigDecimal("80"), holding.cost_basis
      assert_equal "provider", holding.cost_basis_source
      assert_equal "USD", holding.currency
      assert_equal Date.current, holding.date
      assert_equal link.id, holding.account_provider_id
      assert_equal security.id, holding.security_id
      assert_equal security.id, holding.provider_security_id
      assert_equal 1, observed_transactions.size
      assert observed_transactions.all?(&:positive?)
    ensure
      Holding.skip_callback(:save, :before, before_save) if before_save
    end
  end

  test "an existing holding keeps its UUID and locked manual cost basis" do
    with_source do |_item, source, account, link, security|
      existing = account.holdings.create!(security: security, account_provider: link,
        external_id: "simplefin_current", date: Date.current, currency: "USD", qty: 1, price: 12, amount: 12,
        cost_basis: 7, cost_basis_source: "manual", cost_basis_locked: true)
      resolve_with(security)

      assert_no_difference "Holding.count" do
        SimplefinAccount::Investments::HoldingsProcessor.new(source).process
      end

      assert_equal existing.id, account.holdings.find_by!(external_id: "simplefin_current").id
      assert_equal BigDecimal("2.5"), existing.reload.qty
      assert_equal BigDecimal("250"), existing.amount
      assert_equal BigDecimal("7"), existing.cost_basis
      assert_equal "manual", existing.cost_basis_source
      assert existing.cost_basis_locked?
    end
  end

  test "a relink during security lookup refuses publication to either financial account" do
    with_source do |item, source, account, link, security|
      other = Account.create!(family: item.family, name: "Replacement owner", currency: "USD", balance: 0, accountable: Investment.new)
      future = future_holding(account, security)
      before = future.attributes
      resolve_with(security) do
        assert_equal 0, ApplicationRecord.connection.open_transactions
        AccountProvider.find(link.id).update!(account: other)
      end

      assert_no_difference "Holding.count" do
        assert_raises(Fence::OwnershipChanged) { SimplefinAccount::Investments::HoldingsProcessor.new(source).process }
      end
      assert_equal before, future.reload.attributes
      assert_empty other.holdings
      assert_not account.holdings.exists?(external_id: "simplefin_current")
    end
  end

  test "replacing the provider link on the same account during lookup is not silently adopted" do
    with_source do |_item, source, account, link, security|
      future = future_holding(account, security)
      before = future.attributes
      replacement = nil
      resolve_with(security) do
        AccountProvider.find(link.id).destroy!
        replacement = AccountProvider.create!(account: account, provider: SimplefinAccount.find(source.id))
      end

      assert_no_difference "Holding.count" do
        assert_raises(Fence::OwnershipChanged) { SimplefinAccount::Investments::HoldingsProcessor.new(source).process }
      end
      assert_not_equal link.id, replacement.id
      assert_equal before, future.reload.attributes
      assert_not account.holdings.exists?(external_id: "simplefin_current")
    end
  end

  test "changing the direct source link during lookup cannot reuse the unchanged provider link" do
    with_source do |_item, source, account, _link, security|
      account.update!(simplefin_account_id: source.id)
      resolve_with(security) { Account.find(account.id).update!(simplefin_account_id: nil) }

      assert_no_difference "Holding.count" do
        assert_raises(Fence::OwnershipChanged) { SimplefinAccount::Investments::HoldingsProcessor.new(source).process }
      end
      assert_nil account.reload.simplefin_account_id
    end
  end

  test "a locked financial account propagates busy after lookup without holding writes or cleanup" do
    with_source do |_item, source, account, _link, security|
      future = future_holding(account, security)
      before = future.attributes
      resolve_with(security) { assert_equal 0, ApplicationRecord.connection.open_transactions }

      with_locked_account(account) do
        assert_no_difference "Holding.count" do
          assert_raises(Fence::Busy) { SimplefinAccount::Investments::HoldingsProcessor.new(source).process }
        end
      end

      assert_equal before, future.reload.attributes
    end
  end

  test "ownership denials from security resolution propagate without an offline fallback" do
    with_source do |_item, source, account, _link, security|
      [ Fence::OwnershipChanged, Fence::Busy, Fence::InvalidSource ].each do |error_class|
        resolver = mock("denied security lookup")
        Security::Resolver.expects(:new).with(security.ticker).returns(resolver)
        resolver.expects(:resolve).raises(error_class, "Ownership was refused")

        assert_no_difference [ "Security.count", "Holding.count" ] do
          assert_raises(error_class) { SimplefinAccount::Investments::HoldingsProcessor.new(source).process }
        end
      end
      assert_empty account.holdings
    end
  end

  test "an ordinary failed holding rolls back independently and later holdings still publish without pruning" do
    with_source do |_item, source, account, _link, security|
      source.update!(raw_holdings_payload: [ payload(security).merge("id" => "broken"), payload(security) ])
      future = future_holding(account, security)
      before = future.attributes
      after_save = lambda do |holding|
        raise IOError, "Simulated holding save failure" if holding.account_id == account.id && holding.external_id == "simplefin_broken"
      end
      Holding.set_callback(:save, :after, after_save)
      resolve_with(security, times: 2) { assert_equal 0, ApplicationRecord.connection.open_transactions }

      assert_difference "Holding.count", 1 do
        SimplefinAccount::Investments::HoldingsProcessor.new(source).process
      end

      assert_not account.holdings.exists?(external_id: "simplefin_broken")
      assert account.holdings.exists?(external_id: "simplefin_current")
      assert_equal before, future.reload.attributes
    ensure
      Holding.skip_callback(:save, :after, after_save) if after_save
    end
  end

  private
    def resolve_with(security, times: 1, &during_lookup)
      resolver = Object.new
      resolver.define_singleton_method(:resolve) do
        during_lookup&.call
        security
      end
      Security::Resolver.expects(:new).with(security.ticker).times(times).returns(resolver)
    end

    def payload(security)
      { "id" => "current", "symbol" => security.ticker, "description" => "Holding",
        "shares" => "2.5", "market_value" => "250", "total_cost" => "200", "currency" => "USD",
        "created" => Time.utc(2020, 1, 1).to_i }
    end

    def future_holding(account, security)
      account.holdings.create!(security: security, external_id: "preserved_future", date: Date.current + 1.day,
        currency: "USD", qty: 1, price: 20, amount: 20)
    end

    def with_source
      with_provider_encryption do
        family = Family.create!(name: "SimpleFIN holdings publication")
        item = SimplefinItem.create!(family: family, name: "SimpleFIN", access_url: "https://example.com/access")
        security = Security.create!(ticker: "SF#{SecureRandom.hex(5).upcase}", name: "Publication test security", offline: true)
        source = item.simplefin_accounts.create!(name: "Brokerage", account_id: SecureRandom.uuid,
          currency: "USD", account_type: "investment", current_balance: 250, raw_holdings_payload: [ payload(security) ])
        account = Account.create!(family: family, name: "Brokerage", currency: "USD", balance: 0, accountable: Investment.new)
        link = AccountProvider.create!(account: account, provider: source)
        yield item, source, account, link, security
      ensure
        if family&.persisted?
          Holding.where(account_id: family.accounts.select(:id)).find_each(&:destroy!)
          AccountProvider.where(account_id: family.accounts.select(:id)).delete_all
          family.accounts.reload.each(&:destroy!)
          item&.reload&.destroy!
          family.destroy!
        end
        security&.destroy!
      end
    end

    def with_locked_account(account)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
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
      yield
    ensure
      release << true if release
      worker&.join(5)
      worker&.kill if worker&.alive?
      worker&.join
    end
end
