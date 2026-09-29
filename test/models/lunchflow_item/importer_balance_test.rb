require "test_helper"

class LunchflowItem::ImporterBalanceTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = LunchflowItem.create!(
      family: @family,
      name: "Balance isolation test",
      api_key: "test_key_123",
      status: :good
    )
    @lunchflow_account = @item.lunchflow_accounts.create!(
      account_id: "acct-balance",
      name: "Linked checking",
      currency: "EUR"
    )
    @account = @family.accounts.create!(
      name: "Linked checking",
      balance: 10,
      currency: "EUR",
      accountable: Depository.new(subtype: "checking")
    )
    AccountProvider.create!(account: @account, provider: @lunchflow_account)

    @provider = mock("lunchflow_provider")
    @provider.stubs(:get_accounts).returns(
      accounts: [
        {
          id: @lunchflow_account.account_id,
          name: "Linked checking",
          currency: "EUR",
          status: "ACTIVE"
        }
      ]
    )
    @importer = LunchflowItem::Importer.new(@item, lunchflow_provider: @provider)
  end

  test "refreshes balance when transaction fetch is rate limited" do
    error = Provider::Lunchflow::LunchflowError.new("Bank data is temporarily unavailable", :rate_limited)
    @provider.expects(:get_account_transactions).raises(error)
    @provider.expects(:get_account_balance).with(@lunchflow_account.account_id).returns(
      balance: { amount: "123.45", currency: "EUR" }
    )

    result = @importer.import

    assert_equal 1, result[:transactions_failed]
    assert_equal 0, result[:balances_failed]
    assert_not result[:success]
    assert_equal BigDecimal("123.45"), @lunchflow_account.reload.current_balance
  end

  test "reports balance failure without suppressing a successful transaction fetch" do
    @provider.expects(:get_account_transactions).returns(transactions: [])
    @provider.expects(:get_account_balance)
      .with(@lunchflow_account.account_id)
      .raises(Provider::Lunchflow::LunchflowError.new("temporarily unavailable", :server_error))

    result = @importer.import

    assert_equal 0, result[:transactions_failed]
    assert_equal 1, result[:balances_failed]
    assert_not result[:success]
    assert_equal BigDecimal("10"), @account.reload.balance
  end

  test "rejects invalid and non-finite balance amounts" do
    @lunchflow_account.update!(current_balance: BigDecimal("10"))

    [ "invalid", "NaN", "Infinity" ].each do |amount|
      @provider.expects(:get_account_balance).returns(balance: { amount: amount, currency: "EUR" })

      assert_not @importer.send(:fetch_and_update_balance, @lunchflow_account)
      assert_equal BigDecimal("10"), @lunchflow_account.reload.current_balance
    end
  end
end
