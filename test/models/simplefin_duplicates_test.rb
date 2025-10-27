require "test_helper"

class SimplefinDuplicatesTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(
      family: @family,
      name: "SF Conn",
      access_url: "https://example.com/sfin"
    )

    @sacc = @item.simplefin_accounts.create!(
      name: "Checking",
      account_id: "acc_1",
      currency: "USD",
      account_type: "checking",
      current_balance: 1000
    )

    # Use an existing account fixture and link to this SimpleFin account
    @account = accounts(:connected)
    @account.update!(simplefin_account: @sacc)
  end

  def process_tx(payload)
    SimplefinEntry::Processor.new(payload, simplefin_account: @sacc).process
  end

  test "dedup by upstream id" do
    payload = {
      id: "tx_1",
      amount: -12.34,
      currency: "USD",
      posted: Date.today,
      description: "Coffee Shop"
    }

    assert_difference -> { @account.entries.count }, +1 do
      process_tx(payload)
    end

    # Same payload again should not create a duplicate
    assert_no_difference -> { @account.entries.count } do
      process_tx(payload)
    end

    assert_equal 1, @account.entries.where(plaid_id: "simplefin_tx_1").count
  end

  test "dedup by fitid when id missing" do
    payload = {
      fitid: "fit_42",
      amount: 50.00,
      currency: "USD",
      posted: Date.today,
      payee: "Payroll"
    }

    assert_difference -> { @account.entries.count }, +1 do
      process_tx(payload)
    end

    assert_no_difference -> { @account.entries.count } do
      process_tx(payload)
    end

    assert_equal 1, @account.entries.where(plaid_id: "simplefin_fitid_fit_42").count
  end

  test "composite duplicate by date/amount/name-like match" do
    today = Date.today

    first = {
      amount: -25.00,
      currency: "USD",
      posted: today,
      payee: "AMAZON",
      description: "MARKETPLACE"
    }

    # First insert creates an entry with a generated name
    assert_difference -> { @account.entries.count }, +1 do
      process_tx(first)
    end

    # Second insert lacks id/fitid and uses a slightly different casing/spacing
    second = {
      amount: -25.0,
      currency: "USD",
      posted: today,
      payee: "amazon ",
      description: " marketplace"
    }

    # Should be treated as duplicate by composite match logic
    assert_no_difference -> { @account.entries.count } do
      process_tx(second)
    end
  end

  test "pending to posted merge upgrades external key and does not duplicate" do
    today = Date.today

    # Simulate an initial pending tx without upstream id/fitid
    pending_payload = {
      amount: -9.99,
      currency: "USD",
      posted: today,
      payee: "APPLE",
      description: "SERVICES"
    }

    assert_difference -> { @account.entries.count }, +1 do
      process_tx(pending_payload)
    end

    # Capture the originally created entry (it will have a plaid_id like "simplefin_..." or nil-composite)
    original_entry = @account.entries.order(:created_at).last

    # Now a posted version arrives with stable upstream id
    posted_payload = pending_payload.merge(id: "stable_123")

    assert_no_difference -> { @account.entries.count } do
      process_tx(posted_payload)
    end

    original_entry.reload
    assert_equal "simplefin_stable_123", original_entry.plaid_id
  end
end
