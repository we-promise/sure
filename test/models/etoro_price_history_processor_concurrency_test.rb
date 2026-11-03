require "test_helper"
require "concurrent"

# eToro's write locks the security it prices, so that a health check or a
# user changing the security waits for it, but it must not wait for the rows
# that refer to the security, nor hold them up: an account sync storing the
# holdings of the security goes on beside it.
#
# Real threads on real connections, so this needs real commits.
class EtoroPriceHistoryProcessorConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @family = Family.create!(name: "eToro price lock", currency: "USD")
    @account = Account.create!(family: @family, name: "eToro", currency: "USD", balance: 0, cash_balance: 0, accountable: Investment.new)
    @item = EtoroItem.create!(family: @family, name: "eToro", api_key: "lock-#{SecureRandom.hex(8)}", user_key: "lock-user")
    @etoro_account = @item.etoro_accounts.create!(etoro_account_id: "real", name: "eToro", currency: "USD")
    @etoro_account.ensure_account_provider!(@account)
    @security = Security.create!(ticker: "LOCK#{SecureRandom.hex(3).upcase}", offline: true)
  end

  teardown do
    Security::Price.where(security_id: @security.id).delete_all
    Holding.where(account_id: @account.id).delete_all
    AccountProvider.where(account_id: @account.id).delete_all
    EtoroAccount.where(id: @etoro_account.id).delete_all
    EtoroItem.where(id: @item.id).delete_all
    @account.destroy
    @family.destroy
    @security.delete
  end

  test "a write does not wait for a transaction that stored a holding of the security" do
    stored = Concurrent::Event.new
    finish = Concurrent::Event.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Holding.transaction do
          @account.holdings.create!(security: @security, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")
          stored.set
          finish.wait(10)
        end
      end
    end
    writer = nil
    written = nil
    begin
      assert stored.wait(5), "the holding must be stored before the write"

      writer = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          EtoroAccount::PriceHistoryProcessor.new(@etoro_account).process(@security, currency: "USD", closes: { Date.current => BigDecimal("10") })
        end
      end
      written = writer.join(5)
    ensure
      # The holder's transaction holds the account row, which teardown
      # deletes, so it ends on every path.
      finish.set
      holder.join
      writer&.join
    end

    assert written, "the write waited for the transaction that stored the holding"
    assert_equal [ 1, EtoroAccount::PriceHistoryProcessor::OFFLINE_REASON ], [ @security.prices.count, @security.reload.offline_reason ]
  end
end
