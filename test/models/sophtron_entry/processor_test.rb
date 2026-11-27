require "test_helper"

class SophtronEntry::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = @family.sophtron_items.create!(
      name: "Sophtron",
      user_id: "developer-user",
      access_key: Base64.strict_encode64("secret-key")
    )
  end

  test "negates amounts from an account-holder-signed depository feed" do
    sophtron_account = create_sophtron_account(account_id: "dep_1", balance: 1000)
    account = link_account(accounts(:depository), sophtron_account)

    assert_equal BigDecimal("12.34"), process(sophtron_account, id: "t1", amount: "-12.34").amount
    assert_equal BigDecimal("-500"), process(sophtron_account, id: "t2", amount: "500").amount
    assert_equal 2, account.entries.where(source: "sophtron").count
  end

  test "automatic credit card mode keeps negating amounts" do
    sophtron_account = create_sophtron_account(account_id: "cc_auto", balance: 250)
    link_account(accounts(:credit_card), sophtron_account)

    assert_equal BigDecimal("-40"), process(sophtron_account, id: "t1", amount: "40").amount
  end

  test "credit card with a debt reported as positive keeps charges as outflows" do
    sophtron_account = create_sophtron_account(account_id: "cc_lender", balance: 250, balance_sign_override: "debt")
    link_account(accounts(:credit_card), sophtron_account)

    assert_equal BigDecimal("40"), process(sophtron_account, id: "charge", amount: "40").amount
    assert_equal BigDecimal("-100"), process(sophtron_account, id: "payment", amount: "-100").amount
  end

  test "credit card with a debt reported as negative still negates amounts" do
    sophtron_account = create_sophtron_account(account_id: "cc_holder", balance: -250, balance_sign_override: "debt")
    link_account(accounts(:credit_card), sophtron_account)

    assert_equal BigDecimal("40"), process(sophtron_account, id: "charge", amount: "-40").amount
    assert_equal BigDecimal("-100"), process(sophtron_account, id: "payment", amount: "100").amount
  end

  test "paying a lender-signed card down to zero keeps charges as outflows on reprocessing" do
    sophtron_account = create_sophtron_account(account_id: "cc_paid_off", balance: 25, balance_sign_override: "debt")
    link_account(accounts(:credit_card), sophtron_account)
    assert_equal BigDecimal("40"), process(sophtron_account, id: "charge", amount: "40").amount

    sophtron_account.update!(balance: 0)

    assert_equal BigDecimal("40"), process(sophtron_account, id: "charge", amount: "40").amount
  end

  private
    def process(sophtron_account, id:, amount:)
      SophtronEntry::Processor.new(
        { id: id, accountId: sophtron_account.account_id, amount: amount, currency: "USD", date: "2026-05-01", merchant: "Coffee Shop" },
        sophtron_account: sophtron_account
      ).process
    end

    def create_sophtron_account(account_id:, balance:, balance_sign_override: nil)
      sophtron_account = @item.sophtron_accounts.create!(
        account_id: account_id,
        name: account_id,
        currency: "USD",
        balance: balance
      )
      sophtron_account.apply_balance_sign_override!(balance_sign_override) if balance_sign_override
      sophtron_account
    end

    def link_account(account, sophtron_account)
      AccountProvider.create!(account: account, provider: sophtron_account)
      sophtron_account.reload
      account
    end
end
