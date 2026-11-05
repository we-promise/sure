# frozen_string_literal: true

require "test_helper"

class WiseItem::ProcessLinkedAccountJobTest < ActiveJob::TestCase
  setup do
    @family = families(:empty)
    @wise_item = WiseItem.create!(family: @family, name: "Test Wise", token: "test_token", profile_id: "123", profile_type: :personal)
    @eur = link_balance("EUR", "10000001")
    @gbp = link_balance("GBP", "10000003")

    conversion = {
      "id" => "interbalance_activity_9000000106",
      "type" => "INTERBALANCE",
      "resource" => { "type" => "BALANCE_TRANSACTION", "id" => "9000000106" },
      "title" => "To <strong>EUR</strong>",
      "primaryAmount" => "1,234.56 EUR",
      "secondaryAmount" => "1,000 GBP",
      "status" => "COMPLETED",
      "createdOn" => "2026-06-23T17:28:46.305Z"
    }
    [ @eur, @gbp ].each { |wise_account| wise_account.update!(raw_transactions_payload: [ conversion ]) }

    # The connection's sync booked Wise EUR; Wise GBP was linked after that
    # sync had picked the accounts it processes.
    WiseAccount::Processor.new(@eur).process
    @inflow = @eur.current_account.entries.find_by!(external_id: "wise_interbalance_9000000106_inflow")
  end

  test "books the balance, links its conversions and recalculates the account" do
    assert_difference -> { @gbp.current_account.syncs.count }, 1 do
      WiseItem::ProcessLinkedAccountJob.perform_now(@gbp)
    end

    outflow = @gbp.current_account.entries.find_by!(external_id: "wise_interbalance_9000000106_outflow")
    transfer = Transfer.find_by!(inflow_transaction_id: @inflow.entryable_id)
    assert_equal outflow.entryable_id, transfer.outflow_transaction_id
    assert transfer.confirmed?
    assert_equal %w[funds_movement funds_movement], [ @inflow, outflow ].map { |entry| entry.entryable.reload.kind }
    assert_empty @wise_item.syncs, "the connection's own sync is left alone"
  end

  # The balance's processing lock keeps the job from interleaving with the
  # connection's sync processing the same balance.
  test "books nothing outside the balance's processing lock" do
    WiseAccount.any_instance.expects(:with_processing_lock).once # never yields

    WiseItem::ProcessLinkedAccountJob.perform_now(@gbp)

    assert_empty @gbp.current_account.entries.where(source: "wise")
    assert_not Transfer.exists?(inflow_transaction_id: @inflow.entryable_id)
  end

  # The job books what a sync stored without knowing whether that sync's
  # import was complete, so it never counts as one (import_complete: false):
  # an entry no stored row books and the opening balance made with the account
  # stay, although the history is covered from before the balance opened.
  test "deletes no entry and leaves the opening balance where it is" do
    @wise_item.update!(import_all_history: true)
    @wise_item.merge_sync_metadata!("coverage" => %w[transfers activities].index_with {
      { "from" => "2020-01-01T00:00:00Z", "through" => Time.current.utc.iso8601, "version" => WiseItem::COVERAGE_VERSION }
    })
    @gbp.update!(raw_payload: @gbp.raw_payload.merge("creationTime" => "2026-04-01T10:00:00Z"))
    account = @gbp.current_account
    # As made with the account: its balance, two years back.
    Account::OpeningBalanceManager.new(account).set_opening_balance(balance: 1250)
    stale = account.entries.create!(external_id: "wise_transfer_999", source: "wise", amount: 10, currency: "GBP",
                                    date: Date.new(2026, 9, 9), name: "Old payout", entryable: Transaction.new)

    WiseItem::ProcessLinkedAccountJob.perform_now(@gbp)

    assert account.entries.exists?(external_id: "wise_interbalance_9000000106_outflow")
    assert Entry.exists?(stale.id), "the job deleted an entry no stored row books"
    anchor = account.valuations.opening_anchor.sole.entry.reload
    assert_equal [ 2.years.ago.to_date, BigDecimal("1250") ], [ anchor.date, anchor.amount ]
  end

  # The job can run before the connection's sync stores this build's
  # payloads, on what an older build stored: every conversion and jar move of
  # the profile on every balance. None of them books on a balance they never
  # touched.
  test "books no conversion or jar move of other currencies an older build stored on the balance" do
    usd = link_balance("USD", "10000004")
    old_build_rows = [
      { "id" => "interbalance_activity_77", "type" => "INTERBALANCE", "resource" => { "type" => "BALANCE_TRANSACTION", "id" => "77" },
        "title" => "To <strong>GBP</strong>", "primaryAmount" => "860 GBP", "secondaryAmount" => "1,000 EUR", "status" => "COMPLETED",
        "createdOn" => "2024-05-02T10:00:00.000Z" },
      { "id" => "interbalance_activity_78", "type" => "INTERBALANCE", "resource" => { "type" => "BALANCE_TRANSACTION", "id" => "78" },
        "title" => "To <strong>Holiday</strong>", "primaryAmount" => "200 EUR", "status" => "COMPLETED", "createdOn" => "2024-06-02T10:00:00.000Z" }
    ]
    usd.update!(raw_transactions_payload: old_build_rows)

    WiseItem::ProcessLinkedAccountJob.perform_now(usd)

    assert_empty usd.current_account.entries.where(source: "wise")
  end

  # Quietly: without linking or a log entry.
  test "does nothing for a balance unlinked before the job ran" do
    account = @gbp.current_account
    @gbp.account_provider.destroy!
    WiseItem.any_instance.expects(:link_jar_transfers!).never

    assert_no_difference "DebugLogEntry.count" do
      WiseItem::ProcessLinkedAccountJob.perform_now(@gbp.reload)
    end

    assert_empty account.entries.where(source: "wise")
    assert_empty account.syncs
  end

  test "does nothing while the connection is being deleted" do
    @wise_item.update_column(:scheduled_for_deletion, true)

    WiseItem::ProcessLinkedAccountJob.perform_now(@gbp)

    assert_empty @gbp.current_account.entries.where(source: "wise")
    assert_empty @gbp.current_account.syncs
  end

  # The next sync processes the balance anyway, so a failure is logged for
  # support rather than retried for weeks.
  test "logs a processing failure for support instead of raising" do
    WiseAccount::Processor.any_instance.stubs(:process).raises(StandardError, "boom")

    assert_difference "DebugLogEntry.count", 1 do
      WiseItem::ProcessLinkedAccountJob.perform_now(@gbp)
    end

    log = DebugLogEntry.order(:created_at).last
    assert_equal "provider_sync_error", log.category
    assert_equal "wise", log.provider_key
    assert_equal @gbp.account_provider, log.account_provider
    assert_equal "StandardError", log.metadata["error_class"]
    assert_empty @gbp.current_account.syncs
  end

  test "retries a deadlock with the connection's sync" do
    WiseAccount::Processor.any_instance.stubs(:process).raises(ActiveRecord::Deadlocked)

    assert_no_difference "DebugLogEntry.count" do
      assert_enqueued_with(job: WiseItem::ProcessLinkedAccountJob, args: [ @gbp ]) do
        WiseItem::ProcessLinkedAccountJob.perform_now(@gbp)
      end
    end
  end

  private

    def link_balance(currency, balance_id)
      wise_account = WiseAccount.create!(wise_item: @wise_item, balance_id: balance_id, name: "Wise #{currency}",
                                         currency: currency, current_balance: 0, raw_payload: { "type" => "STANDARD" })
      AccountProvider.create!(
        account: Account.create!(family: @family, name: "Wise #{currency}", accountable: Depository.new(subtype: "checking"),
                                 balance: 0, currency: currency),
        provider: wise_account
      )
      wise_account
    end
end
