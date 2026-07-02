require "test_helper"

class UpItem::ImporterTest < ActiveSupport::TestCase
  class FakeUpProvider
    attr_reader :transaction_calls

    def initialize(accounts: nil, transactions: nil)
      @transaction_calls = []
      @accounts = accounts
      @transactions = transactions
    end

    def get_accounts
      @accounts || [
        {
          id: "acc_123",
          displayName: "Up Spending",
          accountType: "TRANSACTIONAL",
          ownershipType: "INDIVIDUAL",
          balance: { currencyCode: "AUD", value: "123.45", valueInBaseUnits: 12345 }
        }
      ]
    end

    def get_account_transactions(account_id:, since: nil)
      @transaction_calls << { account_id: account_id, since: since }
      @transactions || [ settled_transaction ]
    end

    private

      def settled_transaction
        {
          id: "tx_1",
          account_id: "acc_123",
          status: "SETTLED",
          description: "Posted transaction",
          amount: { currencyCode: "AUD", value: "-20.00", valueInBaseUnits: -2000 },
          settledAt: "2026-01-19T00:00:00+11:00",
          createdAt: "2026-01-19T00:00:00+11:00"
        }
      end
  end

  setup do
    @family = families(:empty)
    @up_item = UpItem.create!(
      family: @family,
      name: "Test Up",
      access_token: "up-access-token"
    )
    @up_account = UpAccount.create!(
      up_item: @up_item,
      name: "Old name",
      account_id: "acc_123",
      currency: "AUD"
    )
    @account = Account.create!(
      family: @family,
      name: "Spending",
      accountable: Depository.new(subtype: "checking"),
      balance: 0,
      currency: "AUD"
    )
    AccountProvider.create!(account: @account, provider: @up_account)
  end

  test "imports account snapshot and stores transactions" do
    provider = FakeUpProvider.new

    result = UpItem::Importer.new(@up_item, up_provider: provider).import

    assert result[:success]
    assert_equal 1, result[:accounts_updated]
    assert_equal 1, result[:transactions_imported]

    @up_account.reload
    assert_equal "Up Spending", @up_account.name
    assert_equal BigDecimal("123.45"), @up_account.current_balance
    assert_equal "TRANSACTIONAL", @up_account.account_type
    assert_equal "acc_123", provider.transaction_calls.first[:account_id]

    assert_equal [ "tx_1" ], @up_account.raw_transactions_payload.map { |tx| tx["id"] }
  end

  test "held transaction settling under the same id clears pending without duplicates" do
    import_with(transactions: [ held_transaction(id: "tx_h1", amount: "-8.00") ])
    process_transactions

    assert_equal 1, pending_entries.count

    import_with(transactions: [ settled(id: "tx_h1", amount: "-8.00") ])
    process_transactions

    assert_empty pending_entries
    assert_equal 1, @account.entries.where(source: "up").count
    entry = @account.entries.find_by(external_id: "up_tx_h1", source: "up")
    assert_equal false, entry.entryable.pending?
  end

  test "removes held transactions that disappear from the latest fetch" do
    import_with(transactions: [ held_transaction(id: "tx_h2", amount: "-8.00") ])
    process_transactions

    assert_equal 1, pending_entries.count

    import_with(transactions: [])
    process_transactions

    @up_account.reload
    assert_empty pending_entries
    assert_empty @up_account.raw_transactions_payload.select { |tx| UpEntry::Processor.pending?(tx) }
  end

  private

    def import_with(transactions:)
      provider = FakeUpProvider.new(transactions: transactions)
      UpItem::Importer.new(@up_item, up_provider: provider).import
    end

    def process_transactions
      UpAccount::Transactions::Processor.new(@up_account.reload).process
    end

    def pending_entries
      @account.entries
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(source: "up")
        .where("(transactions.extra -> 'up' ->> 'pending')::boolean = true")
    end

    def held_transaction(id:, amount:, date: "2026-01-15T00:00:00+11:00")
      {
        id: id,
        account_id: "acc_123",
        status: "HELD",
        description: "Pending card auth",
        amount: { currencyCode: "AUD", value: amount, valueInBaseUnits: (amount.to_f * 100).to_i },
        settledAt: nil,
        createdAt: date
      }
    end

    def settled(id:, amount:, date: "2026-01-16T00:00:00+11:00")
      {
        id: id,
        account_id: "acc_123",
        status: "SETTLED",
        description: "Posted card auth",
        amount: { currencyCode: "AUD", value: amount, valueInBaseUnits: (amount.to_f * 100).to_i },
        settledAt: date,
        createdAt: date
      }
    end
end
