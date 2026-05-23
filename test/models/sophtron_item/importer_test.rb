require "test_helper"

class SophtronItem::ImporterTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

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

  test "missing user institution id fails import and marks item requires update" do
    account = accounts(:depository)
    sophtron_account = @item.sophtron_accounts.create!(
      account_id: "acct-1",
      name: "Checking",
      currency: "USD",
      balance: 100
    )
    AccountProvider.create!(account: account, provider: sophtron_account)
    @item.update!(user_institution_id: nil, status: :good, last_connection_error: nil)

    provider = mock
    provider.expects(:get_accounts).never

    result = SophtronItem::Importer.new(@item, sophtron_provider: provider).import

    assert_not result[:success]
    assert_equal "Sophtron institution connection is incomplete", result[:error]
    assert_equal "requires_update", @item.reload.status
    assert_equal "Sophtron institution connection is incomplete", @item.last_connection_error
  end

  test "initial linked account import fetches transactions without starting a refresh job" do
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
    provider.expects(:refresh_account).never
    provider.expects(:get_account_transactions).with("acct-1", start_date: anything).returns({
      transactions: [
        {
          id: "tx-1",
          accountId: "acct-1",
          amount: "-12.34",
          currency: "USD",
          date: "2026-05-01",
          merchant: "Coffee Shop",
          description: "Coffee Shop"
        }.with_indifferent_access
      ],
      total: 1
    })

    result = SophtronItem::Importer.new(@item, sophtron_provider: provider).import

    assert result[:success]
    assert_equal 1, result[:transactions_imported]
    assert_equal 1, sophtron_account.reload.raw_transactions_payload.count
  end

  test "automatic import skips linked accounts that require manual sync" do
    account = accounts(:depository)
    sophtron_account = @item.sophtron_accounts.create!(
      account_id: "acct-1",
      name: "Checking",
      currency: "USD",
      balance: 100,
      manual_sync: true
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
    provider.expects(:refresh_account).never
    provider.expects(:get_account_transactions).never

    result = SophtronItem::Importer.new(@item, sophtron_provider: provider).import

    assert result[:success]
    assert_equal 0, result[:transactions_imported]
    assert_nil sophtron_account.reload.raw_transactions_payload
  end

  test "later sync refreshes account after an empty initial transaction fetch" do
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
    provider.expects(:refresh_account).never
    provider.expects(:get_account_transactions).with("acct-1", start_date: anything).returns({
      transactions: [],
      total: 0
    })

    result = SophtronItem::Importer.new(@item, sophtron_provider: provider).import

    assert result[:success]
    assert_equal [], sophtron_account.reload.raw_transactions_payload

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
    provider.expects(:get_job_information).with("refresh-job").returns({ LastStatus: "Completed" })
    provider.expects(:get_account_transactions).with("acct-1", start_date: anything).returns({
      transactions: [
        {
          id: "tx-1",
          accountId: "acct-1",
          amount: "-12.34",
          currency: "USD",
          date: "2026-05-01",
          merchant: "Coffee Shop",
          description: "Coffee Shop"
        }.with_indifferent_access
      ],
      total: 1
    })

    result = SophtronItem::Importer.new(@item, sophtron_provider: provider).import

    assert result[:success]
    assert_equal 1, result[:transactions_imported]
    assert_equal 1, sophtron_account.reload.raw_transactions_payload.count
  end

  test "completed item sync with no stored transaction payload refreshes before fetching" do
    account = accounts(:depository)
    sophtron_account = @item.sophtron_accounts.create!(
      account_id: "acct-1",
      name: "Checking",
      currency: "USD",
      balance: 100
    )
    AccountProvider.create!(account: account, provider: sophtron_account)
    @item.stubs(:last_synced_at).returns(Time.current)

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
    provider.expects(:get_job_information).with("refresh-job").returns({ LastStatus: "Completed" })
    provider.expects(:get_account_transactions).with("acct-1", start_date: anything).returns({
      transactions: [
        {
          id: "tx-1",
          accountId: "acct-1",
          amount: "-12.34",
          currency: "USD",
          date: "2026-05-01",
          merchant: "Coffee Shop",
          description: "Coffee Shop"
        }.with_indifferent_access
      ],
      total: 1
    })

    result = SophtronItem::Importer.new(@item, sophtron_provider: provider).import

    assert result[:success]
    assert_equal 1, sophtron_account.reload.raw_transactions_payload.count
  end

  test "marks item requires update when refresh job requires mfa" do
    account = accounts(:depository)
    sophtron_account = @item.sophtron_accounts.create!(
      account_id: "acct-1",
      name: "Checking",
      currency: "USD",
      balance: 100,
      raw_transactions_payload: [ { id: "existing-tx" } ]
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
    provider.expects(:get_job_information).with("refresh-job").returns({
      SecurityQuestion: [ "Question?" ].to_json,
      LastStatus: "Waiting"
    })

    result = SophtronItem::Importer.new(@item, sophtron_provider: provider).import

    assert_not result[:success]
    assert_equal "requires_update", @item.reload.status
    assert_equal "refresh-job", @item.current_job_id
  end

  test "refresh job still running enqueues poll job without fetching transactions" do
    account = accounts(:depository)
    sophtron_account = @item.sophtron_accounts.create!(
      account_id: "acct-1",
      name: "Checking",
      currency: "USD",
      balance: 100,
      raw_transactions_payload: [ { id: "existing-tx" } ]
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
    provider.expects(:get_job_information).with("refresh-job").returns({ LastStatus: "Started" })
    provider.expects(:get_account_transactions).never

    assert_enqueued_with(job: SophtronRefreshPollJob) do
      result = SophtronItem::Importer.new(@item, sophtron_provider: provider).import

      assert result[:success]
      assert_equal 0, result[:transactions_imported]
      assert_equal 0, result[:transactions_failed]
    end
  end
end
