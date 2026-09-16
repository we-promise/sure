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

  test "skips failed transactions" do
    assert_no_difference "@account.entries.count" do
      result = process(tx(status: "failed"))
      assert_nil result
    end
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
