require "test_helper"
require "ostruct"

class PlaidItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @mock_provider = mock("Provider::Plaid")
    @plaid_item = plaid_items(:one)
    @importer = PlaidItem::Importer.new(@plaid_item, plaid_provider: @mock_provider)
  end

  test "imports item metadata" do
    item_data = OpenStruct.new(
      item_id: "item_1",
      available_products: [ "transactions", "investments", "liabilities" ],
      billed_products: [],
      institution_id: "ins_1",
      institution_name: "First Platypus Bank",
    )

    @mock_provider.expects(:get_item).with(@plaid_item.access_token).returns(
      OpenStruct.new(item: item_data)
    )

    institution_data = OpenStruct.new(
      institution_id: "ins_1",
      institution_name: "First Platypus Bank",
    )

    @mock_provider.expects(:get_institution).with("ins_1").returns(
      OpenStruct.new(institution: institution_data)
    )

    PlaidItem::AccountsSnapshot.any_instance.expects(:accounts).returns([
      OpenStruct.new(
        account_id: "acc_1",
        type: "depository",
      )
    ]).at_least_once

    PlaidItem::AccountsSnapshot.any_instance.expects(:transactions_cursor).returns("test_cursor_1")

    PlaidItem::AccountsSnapshot.any_instance.expects(:get_account_data).with("acc_1").once

    PlaidAccount::Importer.any_instance.expects(:import).once

    @plaid_item.expects(:update!).with(next_cursor: "test_cursor_1")
    @plaid_item.expects(:upsert_plaid_snapshot!).with(item_data)
    @plaid_item.expects(:upsert_plaid_institution_snapshot!).with(institution_data)

    @importer.import
  end

  # The marker is the durable half of the replay: it is cleared only once a sync
  # has actually fetched full history for it.
  test "consumes the replay marker once the replay has been imported" do
    @plaid_item.request_history_replay!
    # Read it back so the value matches the database exactly, since the clear is
    # decided by a WHERE on this column.
    requested_at = @plaid_item.reload.replay_requested_at

    @importer.stubs(:fetch_and_import_item_data)

    PlaidItem::AccountsSnapshot.any_instance.stubs(:accounts).returns([])
    PlaidItem::AccountsSnapshot.any_instance.stubs(:transactions_cursor).returns("test_cursor_1")
    PlaidItem::AccountsSnapshot.any_instance.stubs(:replay_consumed_at).returns(requested_at)

    @importer.import

    assert_equal "test_cursor_1", @plaid_item.reload.next_cursor
    refute @plaid_item.replay_pending?, "the served replay request should be cleared"
  end

  # A replay asked for while the sync was already running was not served by it,
  # so it has to survive to be honoured by the next sync.
  test "keeps a replay requested after the cursor was read" do
    @plaid_item.request_history_replay!
    served_at = 1.hour.ago.change(usec: 0)

    @importer.stubs(:fetch_and_import_item_data)

    PlaidItem::AccountsSnapshot.any_instance.stubs(:accounts).returns([])
    PlaidItem::AccountsSnapshot.any_instance.stubs(:transactions_cursor).returns("test_cursor_1")
    PlaidItem::AccountsSnapshot.any_instance.stubs(:replay_consumed_at).returns(served_at)

    @importer.import

    assert @plaid_item.reload.replay_pending?, "a replay requested mid-sync must not be dropped"
  end

  # The interleaving that in-memory comparison cannot see: another process
  # records a newer request after this sync loaded the record. The clear has to
  # be decided in the database, against the value actually stored there.
  test "keeps a replay written to the database after this sync loaded the item" do
    @plaid_item.request_history_replay!
    served_at = @plaid_item.replay_requested_at

    @importer.stubs(:fetch_and_import_item_data)

    PlaidItem::AccountsSnapshot.any_instance.stubs(:accounts).returns([])
    PlaidItem::AccountsSnapshot.any_instance.stubs(:transactions_cursor).returns("test_cursor_1")
    PlaidItem::AccountsSnapshot.any_instance.stubs(:replay_consumed_at).returns(served_at)

    # A preference change lands mid-sync. Our in-memory copy still holds the
    # older timestamp, so only the database knows this request is outstanding.
    newer_request = 1.minute.from_now.change(usec: 0)
    PlaidItem.where(id: @plaid_item.id).update_all(replay_requested_at: newer_request)

    @importer.import

    assert @plaid_item.reload.replay_pending?,
      "a replay recorded after the item was loaded must not be cleared by this sync"
    assert_equal newer_request.to_i, @plaid_item.replay_requested_at.to_i
  end

  test "clears requires update status after a successful import" do
    @plaid_item.update!(status: :requires_update)
    @importer.stubs(:fetch_and_import_item_data)
    @importer.stubs(:fetch_and_import_accounts_data)

    @importer.import

    assert_predicate @plaid_item.reload, :good?
  end

  test "keeps requires update status when login is still required" do
    @plaid_item.update!(status: :requires_update)
    error = Plaid::ApiError.new(
      code: 400,
      response_body: { "error_code" => "ITEM_LOGIN_REQUIRED" }.to_json
    )
    @importer.stubs(:fetch_and_import_item_data).raises(error)
    @importer.expects(:fetch_and_import_accounts_data).never

    @importer.import

    assert_predicate @plaid_item.reload, :requires_update?
  end
end
