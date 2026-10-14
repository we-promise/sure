require "test_helper"

class GocardlessAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @item = @family.gocardless_items.create!(name: "Test bank", secret_id: "test-id", secret_key: "test-key")
    @provider_account = @item.gocardless_accounts.create!(name: "Test account", currency: "GBP", gocardless_account_id: "test-account")
  end

  test "skips an unlinked account" do
    assert_nil GocardlessAccount::Processor.new(@provider_account).process
  end

  test "preserves the normalised card debt on a linked account" do
    assert_synced_balance CreditCard, "7863.92"
  end

  test "preserves a card in credit as a negative liability" do
    assert_synced_balance CreditCard, "-50.00"
  end

  test "preserves a current account balance" do
    assert_synced_balance Depository, "3335.71"
  end

  test "imports a debit once across repeated syncs" do
    link_account Depository, "100.00"
    @provider_account.update!(raw_transactions_payload: [ {
      "transactionId" => "txn-1", "bookingDate" => Date.current.iso8601,
      "transactionAmount" => { "amount" => "-10.00", "currency" => "GBP" },
      "remittanceInformationUnstructured" => "Coffee", "pending" => false
    } ])
    processor = GocardlessAccount::Transactions::Processor.new(@provider_account)
    assert_equal 1, processor.process[:imported]
    assert_equal 1, processor.process[:imported]
    assert_equal 1, @account.entries.where(source: "gocardless").count
    assert_equal BigDecimal("10.00"), @account.entries.find_by!(source: "gocardless").amount
  end

  test "a booked update clears the pending state for a stable bank id" do
    link_account Depository, "100.00"
    transaction = {
      "transactionId" => "txn-1", "bookingDate" => Date.current.iso8601,
      "transactionAmount" => { "amount" => "-10.00", "currency" => "GBP" },
      "remittanceInformationUnstructured" => "Coffee", "pending" => true
    }
    @provider_account.update!(raw_transactions_payload: [ transaction ])
    processor = GocardlessAccount::Transactions::Processor.new(@provider_account)
    processor.process
    assert @account.entries.find_by!(source: "gocardless").entryable.pending?
    @provider_account.update!(raw_transactions_payload: [ transaction.merge("pending" => false) ])
    processor.process
    assert_not @account.entries.find_by!(source: "gocardless").entryable.pending?
    assert_equal 1, @account.entries.where(source: "gocardless").count
  end

  private

    def link_account(type, balance)
      @account = @family.accounts.create!(name: "Linked account", balance: balance, currency: "GBP", accountable: type.new)
      @provider_account.update!(current_balance: balance)
      @provider_account.ensure_account_provider!(@account)
      @provider_account.reload
    end

    def assert_synced_balance(type, balance)
      link_account type, balance
      GocardlessAccount::Processor.new(@provider_account).process
      assert_equal BigDecimal(balance), @account.reload.balance
      assert_equal BigDecimal(balance), @account.cash_balance
    end
end
