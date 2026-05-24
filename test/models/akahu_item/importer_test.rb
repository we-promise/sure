require "test_helper"

class AkahuItem::ImporterTest < ActiveSupport::TestCase
  class FakeAkahuProvider
    attr_reader :transaction_calls

    def initialize(posted_transactions: nil, pending_transactions: nil, pending_error: nil)
      @transaction_calls = []
      @posted_transactions = posted_transactions
      @pending_transactions = pending_transactions
      @pending_error = pending_error
    end

    def get_accounts
      [
        {
          _id: "acc_123",
          name: "Everyday",
          type: "CHECKING",
          status: "ACTIVE",
          connection: { _id: "conn_1", name: "Test Bank", logo: "https://example.com/logo.png" },
          balance: { currency: "NZD", current: 123.45, available: 100.00 },
          formatted_account: "12-3456-0000000-00",
          meta: { holder: "Test Person" }
        }
      ]
    end

    def get_pending_transactions
      raise Provider::Akahu::AkahuError.new(@pending_error, :server_error) if @pending_error

      @pending_transactions || [
        {
          _id: "pending_1",
          _account: "acc_123",
          date: "2026-01-20",
          description: "Pending transaction",
          amount: -10.00
        }
      ]
    end

    def get_account_transactions(account_id:, start_date: nil, end_date: nil)
      @transaction_calls << { account_id: account_id, start_date: start_date, end_date: end_date }
      @posted_transactions || [
        {
          _id: "tx_1",
          _account: account_id,
          date: "2026-01-19",
          description: "Posted transaction",
          amount: -20.00
        }
      ]
    end
  end

  setup do
    @family = families(:empty)
    @akahu_item = AkahuItem.create!(
      family: @family,
      name: "Test Akahu",
      app_token: "akahu-app-credential",
      user_token: "akahu-user-credential"
    )
    @akahu_account = AkahuAccount.create!(
      akahu_item: @akahu_item,
      name: "Old name",
      account_id: "acc_123",
      currency: "NZD"
    )
    @account = Account.create!(
      family: @family,
      name: "Everyday",
      accountable: Depository.new(subtype: "checking"),
      balance: 0,
      currency: "NZD"
    )
    AccountProvider.create!(account: @account, provider: @akahu_account)
  end

  test "imports account snapshots and stores posted plus pending transactions" do
    provider = FakeAkahuProvider.new

    result = AkahuItem::Importer.new(@akahu_item, akahu_provider: provider).import

    assert result[:success]
    assert_equal 1, result[:accounts_updated]
    assert_equal 2, result[:transactions_imported]

    @akahu_account.reload
    assert_equal "Test Bank - Everyday", @akahu_account.name
    assert_equal BigDecimal("123.45"), @akahu_account.current_balance
    assert_equal "12-3456-0000000-00", @akahu_account.formatted_account
    assert_equal "Test Bank", @akahu_account.institution_metadata["name"]

    transactions = @akahu_account.raw_transactions_payload
    assert_equal [ "tx_1", "pending_1" ], transactions.map { |tx| tx["_id"] }
    assert_equal true, transactions.second["_pending"]
    assert_equal "acc_123", provider.transaction_calls.first[:account_id]
  end

  test "removes pending transactions that disappear from latest pending response" do
    pending = [ pending_transaction(description: "Pending card auth", amount: -8.00) ]
    import_with(pending_transactions: pending, posted_transactions: [])
    process_transactions

    assert_equal 1, pending_entries.count

    import_with(pending_transactions: [], posted_transactions: [])
    process_transactions

    @akahu_account.reload
    assert_empty pending_entries
    assert_empty @akahu_account.raw_transactions_payload.select { |tx| tx["_pending"] }
  end

  test "keeps unchanged pending transactions without creating duplicates" do
    pending = [ pending_transaction(description: "Pending card auth", amount: -8.00) ]
    import_with(pending_transactions: pending, posted_transactions: [])
    process_transactions

    original_entry = pending_entries.first

    import_with(pending_transactions: pending, posted_transactions: [])
    process_transactions

    assert_equal 1, pending_entries.count
    assert_equal original_entry.id, pending_entries.first.id
  end

  test "replaces changed pending transactions" do
    import_with(pending_transactions: [ pending_transaction(description: "Pending card auth", amount: -8.00) ], posted_transactions: [])
    process_transactions

    original_entry = pending_entries.first

    import_with(pending_transactions: [ pending_transaction(description: "Pending card auth", amount: -10.00) ], posted_transactions: [])
    process_transactions

    assert_equal 1, pending_entries.count
    replacement_entry = pending_entries.first
    assert_not_equal original_entry.id, replacement_entry.id
    assert_equal BigDecimal("10.0"), replacement_entry.amount
  end

  test "preserves existing pending transactions when pending fetch fails" do
    pending = [ pending_transaction(description: "Pending card auth", amount: -8.00) ]
    import_with(pending_transactions: pending, posted_transactions: [])
    process_transactions

    original_entry = pending_entries.first

    import_with(posted_transactions: [], pending_error: "Akahu pending unavailable")
    process_transactions

    assert_equal 1, pending_entries.count
    assert_equal original_entry.id, pending_entries.first.id
    assert_equal 1, @akahu_account.reload.raw_transactions_payload.count { |tx| tx["_pending"] }
  end

  test "posted transaction can claim matching pending before stale pending pruning" do
    pending = [ pending_transaction(description: "Pending card auth", amount: -8.00, date: "2026-01-15") ]
    import_with(pending_transactions: pending, posted_transactions: [])
    process_transactions

    original_entry = pending_entries.first
    import_with(
      pending_transactions: [],
      posted_transactions: [
        {
          _id: "posted_1",
          _account: "acc_123",
          date: "2026-01-16",
          description: "Posted card auth",
          amount: -8.00
        }
      ]
    )
    process_transactions

    original_entry.reload
    assert_empty pending_entries
    assert_equal "akahu_posted_1", original_entry.external_id
    assert_equal false, original_entry.entryable.pending?
  end

  private

    def import_with(posted_transactions: [], pending_transactions: [], pending_error: nil)
      provider = FakeAkahuProvider.new(
        posted_transactions: posted_transactions,
        pending_transactions: pending_transactions,
        pending_error: pending_error
      )
      AkahuItem::Importer.new(@akahu_item, akahu_provider: provider).import
    end

    def process_transactions
      AkahuAccount::Transactions::Processor.new(@akahu_account.reload).process
    end

    def pending_entries
      @account.entries
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(source: "akahu")
        .where("(transactions.extra -> 'akahu' ->> 'pending')::boolean = true")
    end

    def pending_transaction(description:, amount:, date: "2026-01-15")
      {
        _account: "acc_123",
        date: date,
        description: description,
        amount: amount,
        type: "DEBIT"
      }
    end
end
