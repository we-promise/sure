require "test_helper"

class EnableBankingAccount::Transactions::ProcessorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)

    @enable_banking_item = EnableBankingItem.create!(
      family:              @family,
      name:                "Test EB Item",
      country_code:        "FR",
      application_id:      "app_id",
      client_certificate:  "cert"
    )
    @enable_banking_account = EnableBankingAccount.create!(
      enable_banking_item: @enable_banking_item,
      name:                "Compte courant",
      uid:                 "uid_txn_proc_test",
      currency:            "EUR",
      current_balance:     1000.00
    )
    AccountProvider.create!(account: @account, provider: @enable_banking_account)
  end

  # Minimal raw transaction payload hash matching the shape EnableBankingEntry::Processor expects
  def raw_pending_transaction(transaction_id:)
    {
      transaction_id:       transaction_id,
      value_date:           3.days.ago.to_date.to_s,
      transaction_amount:   { amount: "25.00", currency: "EUR" },
      credit_debit_indicator: "DBIT",
      _pending:             true
    }
  end

  test "does not re-import a pending transaction whose external_id was manually merged" do
    pending_ext_id = "enable_banking_PDNG_MERGED"

    # Simulate a previously-merged state: a posted transaction carries the pending's external_id
    # in its manual_merge metadata, which is how merge_with_duplicate! records the merge.
    posted_entry = create_transaction(
      account:     @account,
      name:        "Coffee Shop",
      date:        1.day.ago.to_date,
      amount:      25,
      currency:    "EUR",
      external_id: "enable_banking_BOOK_SETTLED",
      source:      "enable_banking"
    )
    posted_entry.transaction.update!(
      extra: {
        "manual_merge" => {
          "merged_from_entry_id"    => SecureRandom.uuid,
          "merged_from_external_id" => pending_ext_id,
          "merged_at"               => Time.current.iso8601,
          "source"                  => "enable_banking"
        }
      }
    )
    posted_entry.mark_user_modified!

    # Raw payload contains the pending transaction that was already merged
    @enable_banking_account.update!(
      raw_transactions_payload: [
        raw_pending_transaction(transaction_id: "PDNG_MERGED")
      ]
    )

    assert_no_difference "@account.entries.count" do
      EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
    end
  end

  test "imports a pending transaction that has NOT been merged" do
    @enable_banking_account.update!(
      raw_transactions_payload: [
        raw_pending_transaction(transaction_id: "PDNG_NEW_UNMERGED")
      ]
    )

    assert_difference "@account.entries.count", 1 do
      EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
    end
  end

  test "imports non-excluded transactions alongside excluded ones in the same batch" do
    pending_ext_id = "enable_banking_PDNG_SKIP_ME"

    posted_entry = create_transaction(
      account:     @account,
      name:        "Already Merged",
      date:        2.days.ago.to_date,
      amount:      15,
      currency:    "EUR",
      external_id: "enable_banking_BOOK_ALREADY",
      source:      "enable_banking"
    )
    posted_entry.transaction.update!(
      extra: {
        "manual_merge" => {
          "merged_from_external_id" => pending_ext_id,
          "merged_at"               => Time.current.iso8601,
          "source"                  => "enable_banking"
        }
      }
    )

    @enable_banking_account.update!(
      raw_transactions_payload: [
        raw_pending_transaction(transaction_id: "PDNG_SKIP_ME"),          # excluded
        raw_pending_transaction(transaction_id: "PDNG_BRAND_NEW_12345")   # should be imported
      ]
    )

    assert_difference "@account.entries.count", 1 do
      EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
    end
  end

  test "excludes all external_ids when multiple pending entries were merged into the same posted entry" do
    pending_ext_id_1 = "enable_banking_PDNG_MULTI_1"
    pending_ext_id_2 = "enable_banking_PDNG_MULTI_2"

    posted_entry = create_transaction(
      account:     @account,
      name:        "Multi Merge",
      date:        2.days.ago.to_date,
      amount:      30,
      currency:    "EUR",
      external_id: "enable_banking_BOOK_MULTI",
      source:      "enable_banking"
    )
    posted_entry.transaction.update!(
      extra: {
        "manual_merge" => [
          { "merged_from_external_id" => pending_ext_id_1, "merged_at" => 2.days.ago.iso8601, "source" => "enable_banking" },
          { "merged_from_external_id" => pending_ext_id_2, "merged_at" => 1.day.ago.iso8601,  "source" => "enable_banking" }
        ]
      }
    )

    @enable_banking_account.update!(
      raw_transactions_payload: [
        raw_pending_transaction(transaction_id: "PDNG_MULTI_1"),  # excluded
        raw_pending_transaction(transaction_id: "PDNG_MULTI_2"),  # excluded
        raw_pending_transaction(transaction_id: "PDNG_MULTI_NEW") # new — should import
      ]
    )

    result = nil
    assert_difference "@account.entries.count", 1 do
      result = EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
    end
    assert_equal 2, result[:skipped]
    assert_equal 1, result[:imported]
  end

  test "handles empty raw_transactions_payload gracefully" do
    @enable_banking_account.update!(raw_transactions_payload: nil)

    result = EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process

    assert_equal true, result[:success]
    assert_equal 0, result[:total]
  end

  test "reports excluded transactions as skipped, not imported or failed" do
    pending_ext_id = "enable_banking_PDNG_SKIP_STATS"

    posted_entry = create_transaction(
      account:     @account,
      name:        "Stats Test",
      date:        2.days.ago.to_date,
      amount:      50,
      currency:    "EUR",
      external_id: "enable_banking_BOOK_STATS",
      source:      "enable_banking"
    )
    posted_entry.transaction.update!(
      extra: { "manual_merge" => { "merged_from_external_id" => pending_ext_id } }
    )

    @enable_banking_account.update!(
      raw_transactions_payload: [
        raw_pending_transaction(transaction_id: "PDNG_SKIP_STATS")
      ]
    )

    result = EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process

    assert_equal true, result[:success]
    assert_equal 1,    result[:skipped]
    assert_equal 0,    result[:imported]
    assert_equal 0,    result[:failed]
  end
end
