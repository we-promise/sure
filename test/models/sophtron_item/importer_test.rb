require "test_helper"

class SophtronItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = @family.sophtron_items.create!(
      name: "Sophtron",
      user_id: "developer-user",
      access_key: Base64.strict_encode64("secret-key"),
      customer_id: "cust-1",
      user_institution_id: "ui-1"
    )
  end

  test "fetches accounts by stored user institution id" do
    provider = mock
    provider.expects(:get_accounts).with("ui-1").returns({
      accounts: [
        {
          account_id: "acct-1",
          account_name: "Checking",
          balance: "100.00",
          balance_currency: "USD",
          currency: "USD"
        }.with_indifferent_access
      ],
      total: 1
    })

    result = SophtronItem::Importer.new(@item, sophtron_provider: provider).import

    assert result[:success]
    assert_equal 1, result[:accounts_created]
    assert_equal "acct-1", @item.sophtron_accounts.first.account_id
  end

  test "marks item requires update when refresh job requires mfa" do
    account = accounts(:depository)
    sophtron_account = @item.sophtron_accounts.create!(
      account_id: "acct-1",
      name: "Checking",
      currency: "USD",
      balance: 100
    )
    AccountProvider.create!(account: account, provider: sophtron_account)

    provider = mock
    provider.expects(:get_accounts).with("ui-1").returns({
      accounts: [
        {
          account_id: "acct-1",
          account_name: "Checking",
          balance: "100.00",
          balance_currency: "USD",
          currency: "USD"
        }.with_indifferent_access
      ],
      total: 1
    })
    provider.expects(:refresh_account).with("acct-1").returns({ JobID: "refresh-job" })
    provider.expects(:poll_job).with("refresh-job").returns({
      SecurityQuestion: [ "Question?" ].to_json,
      LastStatus: "Waiting"
    })

    result = SophtronItem::Importer.new(@item, sophtron_provider: provider).import

    assert_not result[:success]
    assert_equal "requires_update", @item.reload.status
    assert_equal "refresh-job", @item.current_job_id
  end
end
