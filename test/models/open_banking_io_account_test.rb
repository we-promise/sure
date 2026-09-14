require "test_helper"

class OpenBankingIoAccountTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = OpenBankingIoItem.create!(
      family: @family,
      name: "Test open-banking.io",
      api_base_url: "https://api.open-banking.io",
      api_key: "test-api-key",
      private_key: "test-private-key"
    )
    @account = OpenBankingIoAccount.create!(
      open_banking_io_item: @item,
      name: "Test Account",
      account_id: "acc_123",
      currency: "EUR"
    )
  end

  def snapshot(overrides = {})
    {
      id: "acc_123",
      aspsp_name: "Test Bank",
      aspsp_country: "DE",
      currency: "EUR",
      account_type: "CACC",
      iban: "DE00 1234",
      owner_name: "Jane Doe",
      display_name: "Everyday Account",
      balances: [
        { type: "ITBD", name: "Booked", amount: "1234.56", currency: "EUR", reference_date: "2026-01-15" },
        { type: "ITAV", name: "Available", amount: "1200.00", currency: "EUR", reference_date: "2026-01-15" }
      ]
    }.merge(overrides).with_indifferent_access
  end

  # === ACCOUNT TYPE MAP (load-bearing) ===
  test "maps CACC to Depository/checking" do
    @account.update!(account_type: "CACC")
    assert_equal "Depository", @account.suggested_account_type
    assert_equal "checking", @account.suggested_subtype
  end

  test "maps CARD to CreditCard/credit_card" do
    @account.update!(account_type: "CARD")
    assert_equal "CreditCard", @account.suggested_account_type
    assert_equal "credit_card", @account.suggested_subtype
  end

  # SVGS used to be the example here, which encoded "we do not support savings". It is
  # mapped now; OTHR is genuinely ambiguous and stays unmapped on purpose.
  test "unknown account type has no suggestion" do
    @account.update!(account_type: "OTHR")
    assert_nil @account.suggested_account_type
    assert_nil @account.suggested_subtype
  end

  # === BALANCE (load-bearing) ===
  test "upsert stores the ITBD booked balance as current_balance" do
    @account.upsert_open_banking_io_snapshot!(snapshot)
    assert_equal BigDecimal("1234.56"), @account.current_balance
    assert_equal BigDecimal("1200.00"), @account.available_balance
  end

  # Fix 5: booked-preference order ITBD -> CLBD. CLBD is used as current_balance
  # when no ITBD is present.
  test "upsert falls back to the CLBD booked balance when no ITBD is present" do
    @account.upsert_open_banking_io_snapshot!(snapshot(balances: [
      { type: "CLBD", name: "Closing booked", amount: "42.00", currency: "EUR" }
    ]))
    assert_equal BigDecimal("42.00"), @account.current_balance
  end

  # Fix 5: an available-only balance (ITAV) must NOT be silently used as the
  # current (booked) balance.
  test "upsert does not take current_balance from an available-only ITAV balance" do
    @account.update!(current_balance: BigDecimal("100.00"))
    @account.upsert_open_banking_io_snapshot!(snapshot(balances: [
      { type: "ITAV", name: "Available", amount: "1200.00", currency: "EUR" }
    ]))
    assert_equal BigDecimal("100.00"), @account.current_balance
    assert_equal BigDecimal("1200.00"), @account.available_balance
  end

  test "upsert maps display name, account id, formatted account and account type" do
    @account.upsert_open_banking_io_snapshot!(snapshot)
    assert_equal "Everyday Account", @account.name
    assert_equal "acc_123", @account.account_id
    assert_equal "DE00 1234", @account.formatted_account
    assert_equal "CACC", @account.account_type
    assert_equal "open_banking_io", @account.provider
  end

  test "upsert defaults currency to EUR when the reported code is invalid" do
    @account.upsert_open_banking_io_snapshot!(snapshot(currency: "XXX", balances: [ { type: "ITBD", amount: "1.00", currency: "XXX" } ]))
    assert_equal "EUR", @account.currency
  end

  # === ISO 20022 ACCOUNT TYPE MAPPING ===
  # open-banking.io passes through the bank's ExternalCashAccountType1Code. Most EU banks
  # report CACC for every personal account, so "Checking" everywhere is the bank's own
  # classification -- but banks that do distinguish must land on the right subtype.
  test "maps the ISO 20022 cash account types with an unambiguous Sure equivalent" do
    {
      "CACC" => [ "Depository", "checking" ],
      "TRAN" => [ "Depository", "checking" ],
      "SLRY" => [ "Depository", "checking" ],
      "CASH" => [ "Depository", "checking" ],
      "SVGS" => [ "Depository", "savings" ],
      "LLSV" => [ "Depository", "savings" ],
      "ONDP" => [ "Depository", "savings" ],
      "MOMA" => [ "Depository", "money_market" ],
      "CARD" => [ "CreditCard", "credit_card" ],
      "LOAN" => [ "Loan", nil ],
      "MGLD" => [ "Loan", nil ]
    }.each do |code, (type, subtype)|
      account = OpenBankingIoAccount.new(account_type: code)
      assert_equal type, account.suggested_account_type, code
      assert_equal subtype, account.suggested_subtype, code
    end
  end

  test "every mapped subtype is valid for its accountable type" do
    OpenBankingIoAccount::OPEN_BANKING_IO_ACCOUNT_TYPE_MAP.each do |code, mapping|
      subtype = mapping[:subtype]
      next if subtype.nil?

      valid = mapping[:accountable_type].constantize::SUBTYPES.keys
      assert_includes valid, subtype, "#{code} maps to a subtype #{mapping[:accountable_type]} does not define"
    end
  end

  # Guessing wrong is worse than asking: the setup screen offers a type picker.
  test "ambiguous codes are left for the user to choose" do
    %w[OTHR SACC TAXE TRAS CHAR COMM CPAC NREX ODFT].each do |code|
      assert_nil OpenBankingIoAccount.new(account_type: code).suggested_account_type, code
    end
  end

  test "account type matching is case-insensitive" do
    assert_equal "Depository", OpenBankingIoAccount.new(account_type: "svgs").suggested_account_type
    assert_equal "savings", OpenBankingIoAccount.new(account_type: "svgs").suggested_subtype
  end
end
