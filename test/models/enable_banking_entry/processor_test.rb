require "test_helper"

class EnableBankingEntry::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @enable_banking_item = EnableBankingItem.create!(
      family: @family,
      name: "Test Enable Banking",
      country_code: "DE",
      application_id: "test_app_id",
      client_certificate: "test_cert"
    )
    @enable_banking_account = EnableBankingAccount.create!(
      enable_banking_item: @enable_banking_item,
      name: "N26 Hauptkonto",
      uid: "eb_uid_1",
      currency: "EUR"
    )
    AccountProvider.create!(
      account: @account,
      provider: @enable_banking_account
    )
  end

  test "uses entry_reference as external_id when transaction_id is nil" do
    tx = {
      entry_reference: "31e13269-03fc-11f1-89d2-cd465703551c",
      transaction_id: nil,
      booking_date: Date.current.to_s,
      transaction_amount: { amount: "11.65", currency: "EUR" },
      creditor: { name: "Spar Dankt 3418" },
      credit_debit_indicator: "DBIT",
      status: "BOOK"
    }

    assert_difference "@account.entries.count", 1 do
      EnableBankingEntry::Processor.new(tx, enable_banking_account: @enable_banking_account).process
    end

    entry = @account.entries.find_by!(
      external_id: "enable_banking_31e13269-03fc-11f1-89d2-cd465703551c",
      source: "enable_banking"
    )
    assert_equal 11.65, entry.amount.to_f
    assert_equal "EUR", entry.currency
  end

  test "uses transaction_id as external_id when present" do
    tx = {
      entry_reference: "ref_123",
      transaction_id: "txn_456",
      booking_date: Date.current.to_s,
      transaction_amount: { amount: "25.00", currency: "EUR" },
      creditor: { name: "Amazon" },
      credit_debit_indicator: "DBIT",
      status: "BOOK"
    }

    EnableBankingEntry::Processor.new(tx, enable_banking_account: @enable_banking_account).process

    entry = @account.entries.find_by!(external_id: "enable_banking_txn_456", source: "enable_banking")
    assert_equal 25.0, entry.amount.to_f
  end

  test "does not create duplicate when same entry_reference is processed twice" do
    tx = {
      entry_reference: "unique_ref_abc",
      transaction_id: nil,
      booking_date: Date.current.to_s,
      transaction_amount: { amount: "50.00", currency: "EUR" },
      creditor: { name: "Rewe" },
      credit_debit_indicator: "DBIT",
      status: "BOOK"
    }

    assert_difference "@account.entries.count", 1 do
      EnableBankingEntry::Processor.new(tx, enable_banking_account: @enable_banking_account).process
    end

    assert_no_difference "@account.entries.count" do
      EnableBankingEntry::Processor.new(tx, enable_banking_account: @enable_banking_account).process
    end
  end

  test "raises ArgumentError when both transaction_id and entry_reference are nil" do
    tx = {
      transaction_id: nil,
      entry_reference: nil,
      booking_date: Date.current.to_s,
      transaction_amount: { amount: "10.00", currency: "EUR" },
      creditor: { name: "Test" },
      credit_debit_indicator: "DBIT",
      status: "BOOK"
    }

    assert_raises(ArgumentError) do
      EnableBankingEntry::Processor.new(tx, enable_banking_account: @enable_banking_account).process
    end
  end

  test "handles string keys in transaction data" do
    tx = {
      "entry_reference" => "string_key_ref",
      "transaction_id" => nil,
      "booking_date" => Date.current.to_s,
      "transaction_amount" => { "amount" => "15.00", "currency" => "EUR" },
      "creditor" => { "name" => "Lidl" },
      "credit_debit_indicator" => "DBIT",
      "status" => "BOOK"
    }

    assert_difference "@account.entries.count", 1 do
      EnableBankingEntry::Processor.new(tx, enable_banking_account: @enable_banking_account).process
    end

    entry = @account.entries.find_by!(external_id: "enable_banking_string_key_ref", source: "enable_banking")
    assert_equal 15.0, entry.amount.to_f
  end
end
