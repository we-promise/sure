require "test_helper"

class LunchflowAccount::Transactions::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @lunchflow_item = LunchflowItem.create!(name: "Test Lunchflow Connection", api_key: "test_key", family: @family)
    @lunchflow_account = LunchflowAccount.create!(
      lunchflow_item: @lunchflow_item,
      name: "Test Account",
      currency: "EUR",
      account_id: "lf_acc_123"
    )
    @account = Account.create!(
      family: @family,
      name: "Test Checking",
      accountable: Depository.new(subtype: "checking"),
      balance: 1000,
      currency: "EUR"
    )
    AccountProvider.create!(account: @account, provider: @lunchflow_account)
    @lunchflow_account.reload
  end

  test "keeps one entry for a posted transaction without an id across syncs" do
    store [ coffee("isPending" => false) ]

    3.times { process }

    assert_equal 1, lunchflow_entries.count
    assert_match(/\Alunchflow_pending_[a-f0-9]{32}\z/, lunchflow_entries.first.external_id)
  end

  test "keeps one entry when the isPending field is absent" do
    store [ coffee ]

    3.times { process }

    assert_equal 1, lunchflow_entries.count
  end

  test "keeps identical purchases without an id apart, and stable across syncs" do
    store [ coffee("isPending" => false), coffee("isPending" => false) ]

    process
    first_ids = lunchflow_entries.pluck(:external_id).sort
    2.times { process }

    assert_equal 2, first_ids.size
    assert_equal first_ids, lunchflow_entries.pluck(:external_id).sort
    assert_equal [ first_ids.first, "#{first_ids.first}_1" ], first_ids
  end

  test "keeps identical pending purchases without an id apart" do
    store [ coffee("isPending" => true), coffee("isPending" => true) ]

    2.times { process }

    assert_equal 2, lunchflow_entries.count
    assert lunchflow_entries.all? { |entry| entry.entryable.pending? }
  end

  test "settles a pending transaction without an id once and keeps it settled" do
    store [ coffee("isPending" => true) ]
    process
    pending_entry = lunchflow_entries.sole
    assert pending_entry.entryable.pending?

    # The importer replaces the stored row when it settles; the content hash ignores isPending.
    store [ coffee("isPending" => false) ]
    2.times { process }

    settled_entry = lunchflow_entries.sole
    assert_equal pending_entry.id, settled_entry.id
    assert_not settled_entry.entryable.reload.pending?
  end

  test "adds only the new purchase when an identical one shows up in a later sync" do
    store [ coffee("isPending" => false) ]
    process
    original = lunchflow_entries.sole

    store [ coffee("isPending" => false), coffee("isPending" => false) ]
    2.times { process }

    assert_equal 2, lunchflow_entries.count
    assert_equal [ original.external_id, "#{original.external_id}_1" ], lunchflow_entries.pluck(:external_id).sort
  end

  test "transactions with an id are unaffected by identical transactions without one" do
    store [
      coffee("id" => "tx_1", "isPending" => false),
      coffee("isPending" => false),
      coffee("id" => "tx_2", "isPending" => false)
    ]

    2.times { process }

    assert_equal 3, lunchflow_entries.count
    assert_includes lunchflow_entries.pluck(:external_id), "lunchflow_tx_1"
    assert_includes lunchflow_entries.pluck(:external_id), "lunchflow_tx_2"
  end

  private

    def coffee(overrides = {})
      {
        "id" => "",
        "accountId" => @lunchflow_account.account_id,
        "amount" => -4.20,
        "currency" => "EUR",
        "date" => "2026-10-19",
        "merchant" => "Cafe Central",
        "description" => "Latte"
      }.merge(overrides)
    end

    def store(transactions)
      @lunchflow_account.upsert_lunchflow_transactions_snapshot!(transactions)
    end

    def process
      LunchflowAccount::Transactions::Processor.new(@lunchflow_account.reload).process
    end

    def lunchflow_entries
      @account.entries.where(source: "lunchflow")
    end
end
