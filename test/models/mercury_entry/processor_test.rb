# frozen_string_literal: true

require "test_helper"

class MercuryEntry::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family  = families(:dylan_family)
    @account = @family.accounts.create!(
      name: "Mercury Checking", balance: 0, currency: "USD",
      accountable: Depository.new(subtype: "checking")
    )
    @item = MercuryItem.create!(
      family: @family, name: "Mercury", token: "test_token"
    )
    @mercury_account = @item.mercury_accounts.create!(
      name: "Mercury Checking", account_id: "acc_001", currency: "USD", current_balance: 0
    )
    AccountProvider.create!(provider: @mercury_account, account: @account)
  end

  # ---------------------------------------------------------------------------
  # happy-path posted transaction
  # ---------------------------------------------------------------------------

  test "imports a posted transaction with correct sign conversion" do
    assert_difference "@account.entries.count", 1 do
      process(tx(amount: 150.00, status: "sent"))
    end

    entry = @account.entries.find_by(external_id: "mercury_tx_001", source: "mercury")
    assert entry
    # Mercury positive = inflow; Sure convention negates it → negative
    assert entry.amount.negative?
    assert_in_delta(-150.0, entry.amount.to_f, 0.01)
  end

  test "expense (negative Mercury amount) becomes positive outflow in Sure" do
    assert_difference "@account.entries.count", 1 do
      process(tx(amount: -75.50, status: "sent"))
    end

    entry = @account.entries.find_by(external_id: "mercury_tx_001", source: "mercury")
    assert entry
    assert entry.amount.positive?
    assert_in_delta 75.5, entry.amount.to_f, 0.01
  end

  # ---------------------------------------------------------------------------
  # name resolution
  # ---------------------------------------------------------------------------

  test "prefers counterpartyNickname over counterpartyName over bankDescription" do
    process(tx(counterparty_nickname: "Nick", counterparty_name: "Full Name", bank_description: "Bank Desc"))
    assert_equal "Nick", @account.entries.last.name
  end

  test "falls back to counterpartyName when nickname absent" do
    process(tx(counterparty_name: "Acme Corp"))
    assert_equal "Acme Corp", @account.entries.last.name
  end

  test "falls back to bankDescription when no counterparty" do
    process(tx(bank_description: "ACH Credit"))
    assert_equal "ACH Credit", @account.entries.last.name
  end

  # ---------------------------------------------------------------------------
  # date resolution
  # ---------------------------------------------------------------------------

  test "uses postedAt when present" do
    process(tx(posted_at: "2024-03-15T00:00:00Z", created_at: "2024-03-10T00:00:00Z"))
    assert_equal Date.new(2024, 3, 15), @account.entries.last.date
  end

  test "falls back to createdAt when postedAt absent" do
    process(tx(posted_at: nil, created_at: "2024-03-10T00:00:00Z"))
    assert_equal Date.new(2024, 3, 10), @account.entries.last.date
  end

  # ---------------------------------------------------------------------------
  # notes
  # ---------------------------------------------------------------------------

  test "concatenates note and details with separator" do
    process(tx(note: "Office supplies", details: "Q1 restock"))
    assert_equal "Office supplies - Q1 restock", @account.entries.last.notes
  end

  test "note alone stored without separator" do
    process(tx(note: "Reimbursement"))
    assert_equal "Reimbursement", @account.entries.last.notes
  end

  # ---------------------------------------------------------------------------
  # extra metadata: pending, kind, counterpartyId
  # ---------------------------------------------------------------------------

  test "marks pending transactions in extra" do
    process(tx(status: "pending"))

    entry = @account.entries.find_by(external_id: "mercury_tx_001", source: "mercury")
    assert entry
    assert entry.entryable.extra.dig("mercury", "pending"), "pending flag must be true"
  end

  test "posted transactions have pending=false in extra" do
    process(tx(status: "sent"))

    entry = @account.entries.find_by(external_id: "mercury_tx_001", source: "mercury")
    assert_equal false, entry.entryable.extra.dig("mercury", "pending")
  end

  test "stores transaction kind in extra" do
    process(tx(kind: "externalTransfer"))

    entry = @account.entries.find_by(external_id: "mercury_tx_001", source: "mercury")
    assert_equal "externalTransfer", entry.entryable.extra.dig("mercury", "kind")
  end

  test "stores counterpartyId in extra" do
    process(tx(counterparty_id: "cpty_abc123"))

    entry = @account.entries.find_by(external_id: "mercury_tx_001", source: "mercury")
    assert_equal "cpty_abc123", entry.entryable.extra.dig("mercury", "counterparty_id")
  end

  test "does not store nil kind in extra" do
    process(tx)
    entry = @account.entries.find_by(external_id: "mercury_tx_001", source: "mercury")
    assert_nil entry.entryable.extra.dig("mercury", "kind")
  end

  # ---------------------------------------------------------------------------
  # skipped statuses
  # ---------------------------------------------------------------------------

  %w[failed cancelled blocked reversed].each do |status|
    test "skips #{status} transactions" do
      assert_no_difference "@account.entries.count" do
        result = process(tx(status: status))
        assert_equal :skipped, result
      end
    end
  end

  # ---------------------------------------------------------------------------
  # status changes after import
  # ---------------------------------------------------------------------------

  %w[cancelled blocked failed reversed].each do |status|
    test "removes a pending entry whose transaction became #{status}" do
      process(tx(status: "pending"))
      assert imported_entry

      assert_difference "@account.entries.count", -1 do
        process(tx(status: status))
      end

      assert_nil imported_entry
    end
  end

  test "removes a booked entry whose transaction was later reversed" do
    process(tx(status: "sent"))

    assert_difference "@account.entries.count", -1 do
      process(tx(status: "reversed"))
    end
  end

  test "leaves other entries alone when removing an unsettled one" do
    process(tx(id: "tx_keep", status: "sent"))
    process(tx(id: "tx_gone", status: "pending"))

    process(tx(id: "tx_gone", status: "failed"))

    assert_equal [ "mercury_tx_keep" ], @account.entries.where(source: "mercury").pluck(:external_id)
  end

  test "excludes instead of deleting an unsettled entry the user has edited" do
    process(tx(status: "sent"))
    imported_entry.mark_user_modified!

    assert_no_difference "@account.entries.count" do
      process(tx(status: "reversed"))
    end

    assert imported_entry.excluded?
  end

  test "reports a removed entry as skipped" do
    process(tx(status: "pending"))

    assert_equal :skipped, process(tx(status: "failed"))
  end

  test "excludes instead of deleting an unsettled entry with a locked field" do
    process(tx(status: "sent"))
    imported_entry.lock_attr!(:name)
    assert_not imported_entry.user_modified?

    assert_no_difference "@account.entries.count" do
      process(tx(status: "reversed"))
    end

    assert imported_entry.excluded?
  end

  test "excludes instead of deleting an unsettled entry whose transaction has a locked field" do
    process(tx(status: "sent"))
    imported_entry.entryable.lock_attr!(:category_id)
    assert_not imported_entry.user_modified?

    assert_no_difference "@account.entries.count" do
      process(tx(status: "failed"))
    end

    assert imported_entry.excluded?
  end

  test "reads the entry under a row lock before deciding whether to delete it" do
    process(tx(status: "sent"))

    queries = []
    subscriber = ->(*, payload) { queries << payload[:sql] }
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      process(tx(status: "reversed"))
    end

    assert queries.any? { |sql| sql.include?("FROM \"entries\"") && sql.include?("FOR UPDATE") },
      "expected the entry lookup to take FOR UPDATE"
  end

  test "excludes the split children of an entry whose transaction was reversed" do
    process(tx(status: "sent"))
    children = imported_entry.split!([
      { name: "Part one", amount: -60 },
      { name: "Part two", amount: -40 }
    ])
    assert children.none?(&:excluded?)

    assert_no_difference "@account.entries.count" do
      process(tx(status: "reversed"))
    end

    assert imported_entry.excluded?
    assert_equal 2, imported_entry.child_entries.count
    assert imported_entry.child_entries.all?(&:excluded?)
  end

  test "reopens the goal pledge a removed entry had satisfied" do
    pledge = pledge_matched_by_inflow

    assert_difference "@account.entries.count", -1 do
      process(tx(status: "reversed", posted_at: Time.current.iso8601))
    end

    pledge.reload
    assert pledge.status_open?
    assert_nil pledge.matched_transaction_id
  end

  test "reopens the goal pledge when the entry is kept and excluded instead" do
    pledge = pledge_matched_by_inflow
    imported_entry.mark_user_modified!
    transaction = imported_entry.entryable

    process(tx(status: "reversed", posted_at: Time.current.iso8601))

    pledge.reload
    assert pledge.status_open?
    assert_nil pledge.matched_transaction_id
    assert_nil transaction.reload.extra.dig("goal", "pledge_id")
    assert imported_entry.excluded?
  end

  test "keeps an already excluded entry excluded when its transaction is cancelled" do
    process(tx(status: "pending"))
    imported_entry.update!(excluded: true)

    assert_no_difference "@account.entries.count" do
      process(tx(status: "cancelled"))
    end

    assert imported_entry.excluded?
  end

  test "an unsettled status does not touch an entry another provider imported with the same id" do
    other = @account.entries.create!(
      name: "Other", date: Date.current, amount: 5, currency: "USD",
      external_id: "mercury_tx_001", source: "plaid",
      entryable: Transaction.new
    )

    assert_no_difference "@account.entries.count" do
      process(tx(status: "failed"))
    end

    assert Entry.exists?(other.id)
  end

  # ---------------------------------------------------------------------------
  # idempotency
  # ---------------------------------------------------------------------------

  test "does not create duplicate entries on re-process" do
    process(tx)
    assert_no_difference "@account.entries.count" do
      process(tx)
    end
  end

  # ---------------------------------------------------------------------------
  # merchant creation
  # ---------------------------------------------------------------------------

  test "creates merchant from counterpartyName" do
    process(tx(counterparty_name: "Stripe Inc"))
    entry = @account.entries.find_by(external_id: "mercury_tx_001", source: "mercury")
    assert entry.entryable.merchant.present?
    assert_equal "Stripe Inc", entry.entryable.merchant.name
  end

  # ---------------------------------------------------------------------------
  # missing linked account
  # ---------------------------------------------------------------------------

  test "returns nil when mercury_account has no linked account" do
    AccountProvider.where(provider: @mercury_account).destroy_all

    assert_no_difference "@account.entries.count" do
      result = process(tx)
      assert_nil result
    end
  end

  private

    # A pledge on the account that an inflow imported by the processor satisfies.
    def pledge_matched_by_inflow
      goal = goals(:vacation_italy)
      GoalAccount.create!(goal: goal, account: @account)
      pledge = goal.goal_pledges.create!(account: @account, amount: 100, currency: "USD", kind: "transfer")

      process(tx(status: "sent", posted_at: Time.current.iso8601))
      assert pledge.reload.status_matched?
      assert_equal imported_entry.entryable_id, pledge.matched_transaction_id
      pledge
    end

    def imported_entry
      @account.entries.find_by(external_id: "mercury_tx_001", source: "mercury")
    end

    def process(transaction_data)
      MercuryEntry::Processor.new(transaction_data, mercury_account: @mercury_account).process
    end

    def tx(
      id: "tx_001",
      amount: 100.0,
      status: "sent",
      counterparty_name: nil,
      counterparty_nickname: nil,
      counterparty_id: nil,
      bank_description: "Test Transaction",
      kind: nil,
      note: nil,
      details: nil,
      posted_at: "2024-06-01T12:00:00Z",
      created_at: "2024-06-01T10:00:00Z"
    )
      {
        "id"                  => id,
        "amount"              => amount,
        "status"              => status,
        "counterpartyName"    => counterparty_name,
        "counterpartyNickname" => counterparty_nickname,
        "counterpartyId"      => counterparty_id,
        "bankDescription"     => bank_description,
        "kind"                => kind,
        "note"                => note,
        "details"             => details,
        "postedAt"            => posted_at,
        "createdAt"           => created_at
      }
    end
end
