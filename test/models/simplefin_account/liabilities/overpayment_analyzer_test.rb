require "test_helper"

class SimplefinAccount::Liabilities::OverpaymentAnalyzerTest < ActiveSupport::TestCase
  # Limit fixtures to only what's required to avoid FK validation on unrelated tables
  fixtures :families
  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(family: @family, name: "SimpleFIN", access_url: "https://example.com/token")
    @sfa = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "Test Credit Card",
      account_id: "cc_txn_window_1",
      currency: "USD",
      account_type: "credit",
      current_balance: BigDecimal("-22.72")
    )

    # Avoid cross‑suite fixture dependency by creating a fresh credit card account
    @acct = Account.create!(
      family: @family,
      name: "Test CC",
      balance: 0,
      cash_balance: 0,
      currency: "USD",
      accountable: CreditCard.new
    )
    # Create explicit provider link to ensure FK validity in isolation
    AccountProvider.create!(account: @acct, provider: @sfa)

    # Enable heuristic
    Setting["simplefin_cc_overpayment_detection"] = "true"
    # Loosen thresholds for focused unit tests
    Setting["simplefin_cc_overpayment_min_txns"] = "1"
    Setting["simplefin_cc_overpayment_min_payments"] = "1"
    Setting["simplefin_cc_overpayment_statement_guard_days"] = "0"
  end

  teardown do
    # Disable heuristic to avoid bleeding into other tests
    Setting["simplefin_cc_overpayment_detection"] = nil
    Setting["simplefin_cc_overpayment_min_txns"] = nil
    Setting["simplefin_cc_overpayment_min_payments"] = nil
    Setting["simplefin_cc_overpayment_statement_guard_days"] = nil
    begin
      Rails.cache.delete_matched("simplefin:sfa:#{@sfa.id}:liability_sign_hint") if @sfa&.id
    rescue
      # ignore cache backends without delete_matched
    end
    # Ensure created records are removed to avoid FK validation across examples in single-file runs
    AccountProvider.where(account_id: @acct.id).destroy_all rescue nil
    @acct.destroy! rescue nil
    @sfa.destroy! rescue nil
    @item.destroy! rescue nil
  end

  test "classifies credit when payments exceed charges roughly by observed amount" do
    # Create transactions in Maybe convention for liabilities:
    # charges/spend: positive; payments: negative
    # Observed abs is 22.72; make payments exceed charges by ~22.72
    @acct.entries.delete_all
    @acct.entries.create!(date: 10.days.ago.to_date, name: "Store A", amount: 50, currency: "USD", entryable: Transaction.new)
    # Ensure payments exceed charges by at least observed.abs (~22.72)
    @acct.entries.create!(date: 8.days.ago.to_date,  name: "Payment", amount: -75, currency: "USD", entryable: Transaction.new)

    result = SimplefinAccount::Liabilities::OverpaymentAnalyzer.new(@sfa, observed_balance: @sfa.current_balance).call
    assert_equal :credit, result.classification, "expected classification to be credit"
  end

  test "classifies debt when charges exceed payments" do
    @acct.entries.delete_all
    @acct.entries.create!(date: 12.days.ago.to_date, name: "Groceries", amount: 120, currency: "USD", entryable: Transaction.new)
    @acct.entries.create!(date: 11.days.ago.to_date, name: "Coffee", amount: 10, currency: "USD", entryable: Transaction.new)
    @acct.entries.create!(date: 9.days.ago.to_date,  name: "Payment", amount: -50, currency: "USD", entryable: Transaction.new)

    result = SimplefinAccount::Liabilities::OverpaymentAnalyzer.new(@sfa, observed_balance: BigDecimal("-80")).call
    assert_equal :debt, result.classification, "expected classification to be debt"
  end

  test "returns unknown when insufficient transactions" do
    @acct.entries.delete_all
    @acct.entries.create!(date: 5.days.ago.to_date, name: "Small", amount: 1, currency: "USD", entryable: Transaction.new)

    result = SimplefinAccount::Liabilities::OverpaymentAnalyzer.new(@sfa, observed_balance: BigDecimal("-5")).call
    assert_equal :unknown, result.classification
  end

  test "fallback to raw payload when no entries present" do
    @acct.entries.delete_all
    # Provide raw transactions in provider convention (expenses negative, income positive)
    # We must negate in analyzer to convert to Maybe convention.
    @sfa.update!(raw_transactions_payload: [
      { id: "t1", amount: -100, posted: (10.days.ago.to_date.to_s) }, # charge (-> +100)
      { id: "t2", amount: 150,  posted: (8.days.ago.to_date.to_s) }   # payment (-> -150)
    ])

    result = SimplefinAccount::Liabilities::OverpaymentAnalyzer.new(@sfa, observed_balance: BigDecimal("-50")).call
    assert_equal :credit, result.classification
  end
end
