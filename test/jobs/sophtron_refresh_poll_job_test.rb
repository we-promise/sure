require "test_helper"

class SophtronRefreshPollJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @item = @family.sophtron_items.create!(
      name: "Sophtron",
      user_id: "developer-user",
      access_key: Base64.strict_encode64("secret-key"),
      customer_id: "cust-1",
      user_institution_id: "ui-1"
    )
    @account = accounts(:depository)
    @sophtron_account = @item.sophtron_accounts.create!(
      account_id: "acct-1",
      name: "Checking",
      currency: "USD",
      balance: 100,
      raw_transactions_payload: [ { id: "existing-tx" } ]
    )
    AccountProvider.create!(account: @account, provider: @sophtron_account)
  end

  test "re-enqueues while Sophtron refresh job is still running" do
    provider = mock
    provider.expects(:get_job_information).with("refresh-job").returns({ LastStatus: "Started" })
    SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)

    assert_enqueued_with(job: SophtronRefreshPollJob) do
      SophtronRefreshPollJob.perform_now(@sophtron_account, job_id: "refresh-job", attempts_remaining: 2)
    end
  end

  test "imports transactions and schedules account sync when refresh completes" do
    provider = mock
    provider.expects(:get_job_information).with("refresh-job").returns({ LastStatus: "Completed" })
    SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)
    SophtronItem::Importer.any_instance.expects(:import_transactions_after_refresh)
                           .with(@sophtron_account)
                           .returns({ success: true, transactions_count: 1 })
    SophtronAccount::Processor.any_instance.expects(:process).returns({ transactions_imported: 1 })

    assert_enqueued_with(job: SyncJob) do
      SophtronRefreshPollJob.perform_now(@sophtron_account, job_id: "refresh-job")
    end
  end
end
