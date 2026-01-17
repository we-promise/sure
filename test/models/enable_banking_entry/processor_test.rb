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

  test "includes note field in transaction notes alongside remittance_information" do
    tx = {
      entry_reference: "ref_note",
      transaction_id: nil,
      booking_date: Date.current.to_s,
      transaction_amount: { amount: "10.00", currency: "EUR" },
      credit_debit_indicator: "DBIT",
      remittance_information: [ "Facture 2026-001" ],
      note: "Détail comptable interne",
      status: "BOOK"
    }

    EnableBankingEntry::Processor.new(tx, enable_banking_account: @enable_banking_account).process
    entry = @account.entries.find_by!(external_id: "enable_banking_ref_note")
    assert_includes entry.notes, "Facture 2026-001"
    assert_includes entry.notes, "Détail comptable interne"
  end

  test "stores exchange_rate in extra when present" do
    tx = {
      entry_reference: "ref_fx",
      transaction_id: nil,
      booking_date: Date.current.to_s,
      transaction_amount: { amount: "100.00", currency: "EUR" },
      credit_debit_indicator: "DBIT",
      exchange_rate: {
        unit_currency: "USD",
        exchange_rate: "1.0821",
        rate_type: "SPOT",
        instructed_amount: { amount: "108.21", currency: "USD" }
      },
      status: "BOOK"
    }

    EnableBankingEntry::Processor.new(tx, enable_banking_account: @enable_banking_account).process
    entry = @account.entries.find_by!(external_id: "enable_banking_ref_fx")
    eb_extra = entry.transaction&.extra&.dig("enable_banking")
    assert_equal "1.0821", eb_extra["fx_rate"]
    assert_equal "USD", eb_extra["fx_unit_currency"]
    assert_equal "108.21", eb_extra["fx_instructed_amount"]
  end

  test "stores merchant_category_code in extra when present" do
    tx = {
      entry_reference: "ref_mcc",
      transaction_id: nil,
      booking_date: Date.current.to_s,
      transaction_amount: { amount: "25.00", currency: "EUR" },
      credit_debit_indicator: "DBIT",
      merchant_category_code: "5411",
      status: "BOOK"
    }

    EnableBankingEntry::Processor.new(tx, enable_banking_account: @enable_banking_account).process
    entry = @account.entries.find_by!(external_id: "enable_banking_ref_mcc")
    eb_extra = entry.transaction&.extra&.dig("enable_banking")
    assert_equal "5411", eb_extra["merchant_category_code"]
  end

  test "stores pending true in extra for PDNG-tagged transactions" do
    tx = {
      entry_reference: "ref_pdng",
      transaction_id: nil,
      booking_date: Date.current.to_s,
      transaction_amount: { amount: "15.00", currency: "EUR" },
      credit_debit_indicator: "DBIT",
      status: "PDNG",
      _pending: true
    }

    EnableBankingEntry::Processor.new(tx, enable_banking_account: @enable_banking_account).process
    entry = @account.entries.find_by!(external_id: "enable_banking_ref_pdng")
    eb_extra = entry.transaction&.extra&.dig("enable_banking")
    assert_equal true, eb_extra["pending"]
  end

  test "does not add enable_banking extra key when no extra data present" do
    tx = {
      entry_reference: "ref_noextra",
      transaction_id: nil,
      booking_date: Date.current.to_s,
      transaction_amount: { amount: "5.00", currency: "EUR" },
      credit_debit_indicator: "DBIT",
      status: "BOOK"
    }

    EnableBankingEntry::Processor.new(tx, enable_banking_account: @enable_banking_account).process
    entry = @account.entries.find_by!(external_id: "enable_banking_ref_noextra")
    assert_nil entry.transaction&.extra&.dig("enable_banking")
  end

  def build_name(data)
    processor = EnableBankingEntry::Processor.new(data, enable_banking_account: Object.new)
    processor.send(:name)
  end

  test "skips technical card counterparty and falls back to bank tx description" do
    name = build_name(
      credit_debit_indicator: "CRDT",
      debtor_name: "CARD-1234",
      remittance_information: ["ACME SHOP"],
      bank_transaction_code: { description: "Card Purchase" }
    )

    assert_equal "Card Purchase", name
  end

  test "uses counterparty when it is human readable" do
    name = build_name(
      credit_debit_indicator: "CRDT",
      debtor_name: "ACME SHOP",
      remittance_information: ["Receipt #42"],
      bank_transaction_code: { description: "Transfer" }
    )

    assert_equal "ACME SHOP", name
  end
end
