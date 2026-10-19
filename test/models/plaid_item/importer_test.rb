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
