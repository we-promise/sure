require "test_helper"

class SophtronTransactionsReprocessJobTest < ActiveJob::TestCase
  setup do
    item = families(:dylan_family).sophtron_items.create!(
      name: "Sophtron",
      user_id: "developer-user",
      access_key: Base64.strict_encode64("secret-key")
    )
    @sophtron_account = item.sophtron_accounts.create!(
      account_id: "card-reprocess",
      name: "Card",
      currency: "USD",
      balance: 25,
      raw_transactions_payload: [
        { id: "charge", amount: "40", currency: "USD", date: "2026-05-01", merchant: "Coffee Shop" }
      ]
    )
    @account = accounts(:credit_card)
    AccountProvider.create!(account: @account, provider: @sophtron_account)
  end

  test "re-signs transactions imported before the convention was detected and syncs the account" do
    SophtronAccount::Transactions::Processor.new(@sophtron_account).process
    entry = @account.entries.find_by!(external_id: "sophtron_charge")
    assert_equal BigDecimal("-40"), entry.amount

    @sophtron_account.update!(balance_sign_override: "debt", lender_signed: true)
    Account.any_instance.expects(:sync_later).once

    SophtronTransactionsReprocessJob.perform_now(@sophtron_account)

    assert_equal BigDecimal("40"), entry.reload.amount
  end

  test "retries when a transaction could not be re-signed" do
    SophtronAccount::Transactions::Processor.any_instance.stubs(:process)
      .returns({ success: false, total: 1, imported: 0, failed: 1, errors: [] })
    Account.any_instance.expects(:sync_later).never

    assert_enqueued_with(job: SophtronTransactionsReprocessJob, args: [ @sophtron_account ]) do
      SophtronTransactionsReprocessJob.perform_now(@sophtron_account)
    end
  end

  test "records the failure and still syncs once retries run out" do
    SophtronAccount::Transactions::Processor.any_instance.stubs(:process)
      .returns({ success: false, total: 1, imported: 0, failed: 1, errors: [] })
    Account.any_instance.expects(:sync_later).once

    assert_difference -> { DebugLogEntry.where(provider_key: "sophtron", account: @account).count }, 1 do
      perform_enqueued_jobs(only: SophtronTransactionsReprocessJob) do
        SophtronTransactionsReprocessJob.perform_later(@sophtron_account)
      end
    end
  end

  test "after retries run out, the follow-up sync still waits for a running sync" do
    SophtronAccount::Transactions::Processor.any_instance.stubs(:process)
      .returns({ success: false, total: 1, imported: 0, failed: 1, errors: [] })
    running = @account.syncs.create!(status: "syncing")
    Account.any_instance.expects(:sync_later).never

    perform_enqueued_jobs(only: SophtronTransactionsReprocessJob) do
      SophtronTransactionsReprocessJob.perform_later(@sophtron_account)
    end

    assert_equal [ running ], @account.syncs.reload.to_a
    assert_equal 2, DebugLogEntry.where(provider_key: "sophtron", account: @account).count
  end

  test "a sync-only run does not re-sign transactions" do
    SophtronAccount::Transactions::Processor.expects(:new).never
    Account.any_instance.expects(:sync_later).once

    SophtronTransactionsReprocessJob.perform_now(@sophtron_account, reprocess: false)
  end

  test "waiting for a running sync outlasts the window in which sync_later would join it" do
    attempts = (Sync::VISIBLE_FOR / SophtronTransactionsReprocessJob::SYNC_WAIT).ceil + 2

    assert_operator (attempts - 1) * SophtronTransactionsReprocessJob::SYNC_WAIT, :>, Sync::VISIBLE_FOR
  end

  test "waits for a running account sync instead of joining it" do
    running = @account.syncs.create!(status: "syncing")

    assert_enqueued_with(job: SophtronTransactionsReprocessJob, args: [ @sophtron_account ]) do
      SophtronTransactionsReprocessJob.perform_now(@sophtron_account)
    end
    assert_equal [ running ], @account.syncs.reload.to_a
  end

  test "joins a pending account sync that has not read the amounts yet" do
    pending_sync = @account.syncs.create!

    assert_no_enqueued_jobs(only: SophtronTransactionsReprocessJob) do
      SophtronTransactionsReprocessJob.perform_now(@sophtron_account)
    end
    assert_equal [ pending_sync ], @account.syncs.reload.to_a
  end

  test "does nothing once the account is unlinked" do
    @sophtron_account.account_provider.destroy!
    SophtronAccount::Transactions::Processor.expects(:new).never

    SophtronTransactionsReprocessJob.perform_now(@sophtron_account.reload)
  end
end
