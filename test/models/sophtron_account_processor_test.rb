require "test_helper"

class SophtronAccountProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = @family.sophtron_items.create!(
      name: "Sophtron",
      user_id: "developer-user",
      access_key: Base64.strict_encode64("secret-key")
    )
  end

  test "inverts negative balance for credit card liabilities" do
    sophtron_account = create_sophtron_account(
      account_id: "cc_auto",
      balance: BigDecimal("-123.45")
    )
    acct = link_account(accounts(:credit_card), sophtron_account)

    SophtronAccount::Processor.new(sophtron_account).send(:process_account!)

    assert_equal BigDecimal("123.45"), acct.reload.balance
  end

  test "credit override preserves an ambiguous provider balance as a credit" do
    sophtron_account = create_sophtron_account(
      account_id: "cc_credit",
      balance: BigDecimal("-25"),
      balance_sign_override: "credit"
    )
    acct = link_account(accounts(:credit_card), sophtron_account)

    SophtronAccount::Processor.new(sophtron_account).send(:process_account!)

    assert_equal BigDecimal("-25"), acct.reload.balance
  end

  test "debt override preserves an ambiguous provider balance as debt" do
    sophtron_account = create_sophtron_account(
      account_id: "cc_debt",
      balance: BigDecimal("-25"),
      balance_sign_override: "debt"
    )
    acct = link_account(accounts(:credit_card), sophtron_account)

    SophtronAccount::Processor.new(sophtron_account).send(:process_account!)

    assert_equal BigDecimal("25"), acct.reload.balance
  end

  test "debt override keeps a positive provider balance as debt" do
    sophtron_account = create_sophtron_account(
      account_id: "cc_debt_positive",
      balance: BigDecimal("1947.18"),
      balance_sign_override: "debt"
    )
    acct = link_account(accounts(:credit_card), sophtron_account)

    SophtronAccount::Processor.new(sophtron_account).send(:process_account!)

    assert_equal BigDecimal("1947.18"), acct.reload.balance
  end

  test "does not invert balance for asset accounts" do
    sophtron_account = create_sophtron_account(
      account_id: "dep_1",
      balance: BigDecimal("1000.00")
    )
    acct = link_account(accounts(:depository), sophtron_account)

    SophtronAccount::Processor.new(sophtron_account).send(:process_account!)

    assert_equal BigDecimal("1000.00"), acct.reload.balance
  end

  test "inverts negative balance for loan liabilities even with a credit override" do
    sophtron_account = create_sophtron_account(
      account_id: "loan_1",
      balance: BigDecimal("-400"),
      balance_sign_override: "credit"
    )
    acct = link_account(accounts(:loan), sophtron_account)

    SophtronAccount::Processor.new(sophtron_account).send(:process_account!)

    assert_equal BigDecimal("400"), acct.reload.balance
  end

  private
    def create_sophtron_account(account_id:, balance:, balance_sign_override: nil)
      @item.sophtron_accounts.create!(
        account_id: account_id,
        name: account_id,
        currency: "USD",
        balance: balance,
        balance_sign_override: balance_sign_override
      )
    end

    def link_account(account, sophtron_account)
      AccountProvider.create!(account: account, provider: sophtron_account)
      account
    end
end
