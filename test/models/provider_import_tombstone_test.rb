require "test_helper"

class ProviderImportTombstoneTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository)
    @adapter = Account::ProviderImportAdapter.new(@account)
  end

  test "record_for_entry! tombstones the entry and its retired identities" do
    entry = @adapter.import_transaction(
      external_id: "plaid_booked_1",
      amount: 25.00,
      currency: "USD",
      date: Date.today,
      name: "Booked",
      source: "plaid"
    )
    entry.transaction.update!(
      extra: {
        "superseded_external_ids" => [ "plaid_content_old" ],
        "auto_claimed_pending_ids" => [ "plaid_pending_old" ],
        "manual_merge" => { "merged_from_external_id" => "plaid_merged_old" }
      }
    )

    entry.destroy!

    assert ProviderImportTombstone.tombstoned?(account: @account, source: "plaid", external_id: "plaid_booked_1")
    assert ProviderImportTombstone.tombstoned?(account: @account, source: "plaid", external_id: "plaid_content_old")
    assert ProviderImportTombstone.tombstoned?(account: @account, source: "plaid", external_id: "plaid_pending_old")
    assert ProviderImportTombstone.tombstoned?(account: @account, source: "plaid", external_id: "plaid_merged_old")
    assert_equal 4, ProviderImportTombstone.where(account: @account, source: "plaid").count
  end

  test "record_for_entry! reads the array form of manual_merge" do
    entry = @adapter.import_transaction(
      external_id: "plaid_booked_2",
      amount: 25.00,
      currency: "USD",
      date: Date.today,
      name: "Booked",
      source: "plaid"
    )
    entry.transaction.update!(
      extra: {
        "manual_merge" => [
          { "merged_from_external_id" => "plaid_merged_a" },
          { "merged_from_external_id" => "plaid_merged_b" }
        ]
      }
    )

    entry.destroy!

    assert ProviderImportTombstone.tombstoned?(account: @account, source: "plaid", external_id: "plaid_merged_a")
    assert ProviderImportTombstone.tombstoned?(account: @account, source: "plaid", external_id: "plaid_merged_b")
  end

  test "record_for_entry! ignores manual entries" do
    entry = @account.entries.create!(
      entryable: Transaction.new,
      date: Date.today,
      name: "Manual",
      amount: 10,
      currency: "USD"
    )

    entry.destroy!

    assert_equal 0, ProviderImportTombstone.where(account: @account).count
  end

  test "record_for_entry! is idempotent" do
    entry = @adapter.import_transaction(
      external_id: "plaid_booked_3",
      amount: 25.00,
      currency: "USD",
      date: Date.today,
      name: "Booked",
      source: "plaid"
    )

    ProviderImportTombstone.record_for_entry!(entry)
    ProviderImportTombstone.record_for_entry!(entry)

    assert_equal 1, ProviderImportTombstone.where(account: @account, source: "plaid").count
  end

  test "external_ids_for returns tombstoned ids and clear_for_account! removes one provider's" do
    ProviderImportTombstone.create!(account: @account, source: "plaid", external_id: "plaid_gone")
    ProviderImportTombstone.create!(account: @account, source: "simplefin", external_id: "simplefin_gone")

    assert_equal Set["plaid_gone"], ProviderImportTombstone.external_ids_for(@account, source: "plaid")
    assert_equal 2, ProviderImportTombstone.external_ids_for(@account).size

    assert_equal 1, ProviderImportTombstone.clear_for_account!(account: @account, source: "plaid")
    assert_equal Set["simplefin_gone"], ProviderImportTombstone.external_ids_for(@account)
  end
end
