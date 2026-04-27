require "test_helper"

class GocardlessEntry::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)

    @gocardless_item = GocardlessItem.create!(
      family:       @family,
      name:         "Monzo",
      institution_id:   "MONZO_MONZGB2L",
      institution_name: "Monzo",
      status:       :good,
      requisition_id: "req_test_123"
    )

    @gc_account = GocardlessAccount.create!(
      gocardless_item: @gocardless_item,
      account_id:      "645a6e14-50d5-4a6b-aaba-a9d2a7596a44",
      name:            "Monzo Current Account",
      currency:        "GBP",
      current_balance: 1234.56
    )

    AccountProvider.create!(account: @account, provider: @gc_account)
  end

  # ---------------------------------------------------------------------------
  # Sandbox-style booked transactions (from real GoCardless Nordigen API shape)
  # ---------------------------------------------------------------------------

  BOOKED_PURCHASE = {
    "transactionId"                    => "2026042301773517-1",
    "internalTransactionId"            => "B20260419T142012645abc",
    "bookingDate"                      => "2026-04-19",
    "valueDate"                        => "2026-04-19",
    "transactionAmount"                => { "amount" => "-12.50", "currency" => "GBP" },
    "creditorName"                     => "Freshto Ideal",
    "remittanceInformationUnstructured"=> "Grocery purchase",
    "bankTransactionCode"              => "PMNT",
    "proprietaryBankTransactionCode"   => "PURCHASE"
  }.freeze

  # Same transactionId as BOOKED_PURCHASE — collision the sandbox exhibits
  BOOKED_SALARY = {
    "transactionId"                    => "2026042301773517-1",
    "internalTransactionId"            => "B20260423T083927645xyz",
    "bookingDate"                      => "2026-04-23",
    "valueDate"                        => "2026-04-23",
    "transactionAmount"                => { "amount" => "2500.00", "currency" => "GBP" },
    "debtorName"                       => "Liam Brown",
    "remittanceInformationUnstructured"=> "Salary April 2026",
    "bankTransactionCode"              => "PMNT",
    "proprietaryBankTransactionCode"   => "SALARY"
  }.freeze

  PENDING_COFFEE = {
    "internalTransactionId"          => "P20260424T090000645pnd",
    "valueDate"                      => "2026-04-24",
    "transactionAmount"              => { "amount" => "-5.00", "currency" => "GBP" },
    "creditorName"                   => "Costa Coffee",
    "proprietaryBankTransactionCode" => "PURCHASE",
    "_pending"                       => true
  }.freeze

  NO_REMITTANCE_TRANSFER = {
    "internalTransactionId"          => "B20260420T120000645trf",
    "bookingDate"                    => "2026-04-20",
    "valueDate"                      => "2026-04-20",
    "transactionAmount"              => { "amount" => "-200.00", "currency" => "GBP" },
    "proprietaryBankTransactionCode" => "TRANSFER"
  }.freeze

  # ---------------------------------------------------------------------------
  # External ID — prefers internalTransactionId
  # ---------------------------------------------------------------------------

  test "uses internalTransactionId as external_id" do
    assert_difference "@account.entries.count", 1 do
      process(BOOKED_PURCHASE)
    end

    assert @account.entries.exists?(external_id: "gocardless_B20260419T142012645abc", source: "gocardless")
  end

  test "two transactions with colliding transactionId but different internalTransactionId are both imported" do
    assert_difference "@account.entries.count", 2 do
      process(BOOKED_PURCHASE)
      process(BOOKED_SALARY)
    end
  end

  test "does not create duplicate when same transaction processed twice" do
    process(BOOKED_PURCHASE)

    assert_no_difference "@account.entries.count" do
      process(BOOKED_PURCHASE)
    end
  end

  test "raises ArgumentError when both transactionId and internalTransactionId are absent" do
    tx = { "bookingDate" => "2026-04-19", "transactionAmount" => { "amount" => "-10.00", "currency" => "GBP" } }

    assert_raises(ArgumentError) { process(tx) }
  end

  # ---------------------------------------------------------------------------
  # Amount sign convention (GoCardless negative = debit; app positive = debit)
  # ---------------------------------------------------------------------------

  test "debit purchase amount is positive in app" do
    process(BOOKED_PURCHASE)
    entry = @account.entries.find_by!(external_id: "gocardless_B20260419T142012645abc")
    assert_equal 12.50, entry.amount.to_f
  end

  test "credit salary amount is negative in app" do
    process(BOOKED_SALARY)
    entry = @account.entries.find_by!(external_id: "gocardless_B20260423T083927645xyz")
    assert_equal(-2500.00, entry.amount.to_f)
  end

  # ---------------------------------------------------------------------------
  # Date handling
  # ---------------------------------------------------------------------------

  test "uses bookingDate for booked transactions" do
    process(BOOKED_PURCHASE)
    entry = @account.entries.find_by!(external_id: "gocardless_B20260419T142012645abc")
    assert_equal Date.new(2026, 4, 19), entry.date
  end

  test "pending transaction uses valueDate when no bookingDate" do
    process(PENDING_COFFEE)
    entry = @account.entries.find_by!(external_id: "gocardless_P20260424T090000645pnd")
    assert_equal Date.new(2026, 4, 24), entry.date
  end

  # ---------------------------------------------------------------------------
  # Name resolution
  # ---------------------------------------------------------------------------

  test "uses remittanceInformationUnstructured as name" do
    process(BOOKED_PURCHASE)
    entry = @account.entries.find_by!(external_id: "gocardless_B20260419T142012645abc")
    assert_equal "Grocery purchase", entry.name
  end

  test "falls back to proprietaryBankTransactionCode when no remittance or counterparty" do
    process(NO_REMITTANCE_TRANSFER)
    entry = @account.entries.find_by!(external_id: "gocardless_B20260420T120000645trf")
    assert_equal "TRANSFER", entry.name
  end

  test "uses creditorName when remittance absent but pending has counterparty" do
    tx = PENDING_COFFEE.merge("remittanceInformationUnstructured" => nil)
    process(tx)
    entry = @account.entries.find_by!(external_id: "gocardless_P20260424T090000645pnd")
    assert_equal "Costa Coffee", entry.name
  end

  test "final fallback is generic GoCardless transaction string" do
    tx = {
      "internalTransactionId" => "B20260420T999000645fallback",
      "bookingDate"           => "2026-04-20",
      "transactionAmount"     => { "amount" => "-1.00", "currency" => "GBP" }
    }
    process(tx)
    entry = @account.entries.find_by!(external_id: "gocardless_B20260420T999000645fallback")
    assert_equal "GoCardless transaction", entry.name
  end

  # ---------------------------------------------------------------------------
  # Extra field — transaction codes and pending flag
  # ---------------------------------------------------------------------------

  test "stores bankTransactionCode in extra" do
    process(BOOKED_PURCHASE)
    entry = @account.entries.find_by!(external_id: "gocardless_B20260419T142012645abc")
    assert_equal "PMNT", entry.transaction.extra.dig("gocardless", "transaction_code")
  end

  test "stores proprietaryBankTransactionCode in extra" do
    process(BOOKED_PURCHASE)
    entry = @account.entries.find_by!(external_id: "gocardless_B20260419T142012645abc")
    assert_equal "PURCHASE", entry.transaction.extra.dig("gocardless", "proprietary_transaction_code")
  end

  test "stores salary proprietaryBankTransactionCode in extra" do
    process(BOOKED_SALARY)
    entry = @account.entries.find_by!(external_id: "gocardless_B20260423T083927645xyz")
    assert_equal "SALARY", entry.transaction.extra.dig("gocardless", "proprietary_transaction_code")
  end

  test "stores pending true in extra for pending transactions" do
    process(PENDING_COFFEE)
    entry = @account.entries.find_by!(external_id: "gocardless_P20260424T090000645pnd")
    assert_equal true, entry.transaction.extra.dig("gocardless", "pending")
  end

  test "does not add gocardless extra key when no codes or pending flag" do
    tx = {
      "internalTransactionId" => "B20260420T000000645noextra",
      "bookingDate"           => "2026-04-20",
      "transactionAmount"     => { "amount" => "-10.00", "currency" => "GBP" },
      "creditorName"          => "Test"
    }
    process(tx)
    entry = @account.entries.find_by!(external_id: "gocardless_B20260420T000000645noextra")
    assert_nil entry.transaction.extra&.dig("gocardless")
  end

  # ---------------------------------------------------------------------------
  # Missing linked account
  # ---------------------------------------------------------------------------

  test "returns nil and skips when gocardless_account has no linked account" do
    unlinked_gc = GocardlessAccount.create!(
      gocardless_item: @gocardless_item,
      account_id:      "unlinked-acct-id",
      name:            "Unlinked",
      currency:        "GBP"
    )

    assert_no_difference "Entry.count" do
      result = GocardlessEntry::Processor.new(BOOKED_PURCHASE, gocardless_account: unlinked_gc).process
      assert_nil result
    end
  end

  private

    def process(tx)
      GocardlessEntry::Processor.new(tx, gocardless_account: @gc_account).process
    end
end
