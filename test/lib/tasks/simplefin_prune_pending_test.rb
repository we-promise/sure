# frozen_string_literal: true

require "test_helper"

class SimplefinPrunePendingTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("sure:simplefin:prune_pending")
    Rake::Task["sure:simplefin:prune_pending"].reenable

    @family = families(:dylan_family)
    @account = accounts(:depository)
    @simplefin_item = SimplefinItem.create!(
      family: @family,
      name: "Test SimpleFin Bank",
      access_url: "https://example.com/access_token"
    )
    @simplefin_account = SimplefinAccount.create!(
      simplefin_item: @simplefin_item,
      name: "SF Checking",
      account_id: "sf_acc_1",
      account_type: "checking",
      currency: "USD",
      current_balance: 1000,
      available_balance: 1000,
      account: @account
    )
  end

  test "dry_run defaults to true and leaves the payload untouched" do
    payload = [
      { "id" => "tx_pending", "pending" => true, "posted" => Date.current.to_s, "transacted_at" => (Date.current - 1).to_s },
      { "id" => "tx_posted", "posted" => Date.current.to_s, "transacted_at" => (Date.current - 1).to_s }
    ]
    @simplefin_account.update!(raw_transactions_payload: payload)

    capture_io { Rake::Task["sure:simplefin:prune_pending"].invoke }

    assert_equal payload, @simplefin_account.reload.raw_transactions_payload,
      "dry_run must default to true and never write to raw_transactions_payload"
  end

  test "removes pending rows and keeps non-pending rows when dry_run=false" do
    # Uses the same three shapes covered in SimplefinEntry::ProcessorTest: an explicit
    # pending flag, a settled row, and a malformed non-numeric posted value that must NOT
    # be swept up as pending (regression: SimplefinEntry::Processor.pending? is the single
    # shared definition this task delegates to, so this also guards against the task
    # reintroducing its own posted_val.to_i.zero? bug).
    payload = [
      { "id" => "tx_pending", "pending" => true, "posted" => Date.current.to_s, "transacted_at" => (Date.current - 1).to_s },
      { "id" => "tx_posted", "posted" => Date.current.to_s, "transacted_at" => (Date.current - 1).to_s },
      { "id" => "tx_malformed_posted", "posted" => "unavailable", "transacted_at" => (Date.current - 1).to_s }
    ]
    @simplefin_account.update!(raw_transactions_payload: payload)

    capture_io { Rake::Task["sure:simplefin:prune_pending"].invoke(nil, nil, "false") }

    remaining_ids = @simplefin_account.reload.raw_transactions_payload.map { |tx| tx["id"] }
    assert_equal %w[tx_posted tx_malformed_posted], remaining_ids
  end

  test "never touches Entry/Transaction rows, only the raw payload cache" do
    entry = @account.entries.create!(
      name: "Pre-existing entry",
      date: Date.current,
      amount: 10,
      currency: "USD",
      entryable: Transaction.new
    )

    payload = [ { "id" => "tx_pending", "pending" => true, "posted" => Date.current.to_s, "transacted_at" => (Date.current - 1).to_s } ]
    @simplefin_account.update!(raw_transactions_payload: payload)

    assert_no_difference [ "Entry.count", "Transaction.count" ] do
      capture_io { Rake::Task["sure:simplefin:prune_pending"].invoke(nil, nil, "false") }
    end

    assert entry.reload.persisted?
  end
end
