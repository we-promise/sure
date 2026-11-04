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

  # At institutions with tokenized account numbers, such as Chase, re-consenting
  # through update mode can make Plaid issue a new account_id for an account it
  # already shares. persistent_account_id stays the same across that change.
  test "updates the existing account when Plaid reissues its account_id" do
    existing = plaid_accounts(:one)
    existing.update!(raw_payload: { "account_id" => existing.plaid_id, "persistent_account_id" => "persistent_acc_1" })

    stub_accounts_snapshot(
      raw_plaid_account(account_id: "acc_mock_1_reissued", persistent_account_id: "persistent_acc_1")
    )

    assert_no_difference -> { @plaid_item.plaid_accounts.count } do
      @importer.import
    end

    assert_equal "acc_mock_1_reissued", existing.reload.plaid_id
  end

  test "imports an account with a new persistent_account_id as a new account" do
    existing = plaid_accounts(:one)
    existing.update!(raw_payload: { "account_id" => existing.plaid_id, "persistent_account_id" => "persistent_acc_1" })

    stub_accounts_snapshot(
      raw_plaid_account(account_id: existing.plaid_id, persistent_account_id: "persistent_acc_1"),
      raw_plaid_account(account_id: "acc_new_card", persistent_account_id: "persistent_acc_2")
    )

    assert_difference -> { @plaid_item.plaid_accounts.count }, 1 do
      @importer.import
    end

    assert_equal "acc_mock_1", existing.reload.plaid_id
    assert @plaid_item.plaid_accounts.exists?(plaid_id: "acc_new_card")
  end

  test "does not take over an account Plaid still returns under its own id" do
    existing = plaid_accounts(:one)
    existing.update!(raw_payload: { "account_id" => existing.plaid_id, "persistent_account_id" => "persistent_acc_1" })

    stub_accounts_snapshot(
      raw_plaid_account(account_id: existing.plaid_id, persistent_account_id: "persistent_acc_1"),
      raw_plaid_account(account_id: "acc_mock_1_reissued", persistent_account_id: "persistent_acc_1")
    )

    assert_difference -> { @plaid_item.plaid_accounts.count }, 1 do
      @importer.import
    end

    assert_equal "acc_mock_1", existing.reload.plaid_id
  end

  # Clearing the liabilities of an omitted copy saves it, so the stale copy can
  # carry the newest updated_at.
  test "takes over the newest copy of an already duplicated account" do
    stale = plaid_accounts(:one)
    stale.update!(raw_payload: { "account_id" => stale.plaid_id, "persistent_account_id" => "persistent_acc_1" })
    in_use = duplicate_plaid_account(plaid_id: "acc_mock_1_duplicate", persistent_account_id: "persistent_acc_1")
    AccountProvider.create!(account: accounts(:credit_card), provider: in_use)
    stale.update_columns(created_at: 2.days.ago, updated_at: Time.current)
    in_use.update_columns(created_at: 1.day.ago, updated_at: 1.day.ago)

    stub_accounts_snapshot(
      raw_plaid_account(account_id: "acc_mock_1_reissued", persistent_account_id: "persistent_acc_1")
    )

    assert_no_difference -> { @plaid_item.plaid_accounts.count } do
      @importer.import
    end

    assert_equal "acc_mock_1_reissued", in_use.reload.plaid_id
    assert_equal "acc_mock_1", stale.reload.plaid_id
  end

  test "prefers a copy linked to a Sure account over a newer unlinked copy" do
    linked = plaid_accounts(:one)
    linked.update!(raw_payload: { "account_id" => linked.plaid_id, "persistent_account_id" => "persistent_acc_1" })
    linked.update_columns(created_at: 2.days.ago)
    unlinked = duplicate_plaid_account(plaid_id: "acc_mock_1_duplicate", persistent_account_id: "persistent_acc_1")

    stub_accounts_snapshot(
      raw_plaid_account(account_id: "acc_mock_1_reissued", persistent_account_id: "persistent_acc_1")
    )

    assert_no_difference -> { @plaid_item.plaid_accounts.count } do
      @importer.import
    end

    assert_equal "acc_mock_1_reissued", linked.reload.plaid_id
    assert_equal "acc_mock_1_duplicate", unlinked.reload.plaid_id
  end

  test "imports a reissued account as new when a stored payload cannot be decrypted" do
    existing = plaid_accounts(:one)
    existing.update!(raw_payload: { "account_id" => existing.plaid_id, "persistent_account_id" => "persistent_acc_1" })
    PlaidAccount.any_instance.stubs(:raw_payload).raises(ActiveRecord::Encryption::Errors::Decryption)

    stub_accounts_snapshot(
      raw_plaid_account(account_id: "acc_mock_1_reissued", persistent_account_id: "persistent_acc_1")
    )

    assert_difference -> { @plaid_item.plaid_accounts.count }, 1 do
      @importer.import
    end

    assert_equal "acc_mock_1", existing.reload.plaid_id
    assert DebugLogEntry.exists?(source: "PlaidItem::Importer", level: "warn", provider_key: "plaid")
  end

  test "reads and logs an unreadable payload once per import" do
    existing = plaid_accounts(:one)
    existing.update!(raw_payload: { "account_id" => existing.plaid_id, "persistent_account_id" => "persistent_acc_1" })
    PlaidAccount.any_instance.expects(:raw_payload).once.raises(ActiveRecord::Encryption::Errors::Decryption)

    stub_accounts_snapshot(
      raw_plaid_account(account_id: "acc_mock_1_reissued", persistent_account_id: "persistent_acc_1"),
      raw_plaid_account(account_id: "acc_new_card", persistent_account_id: "persistent_acc_2")
    )

    assert_difference -> { DebugLogEntry.where(source: "PlaidItem::Importer").count }, 1 do
      @importer.import
    end
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

  private
    def raw_plaid_account(account_id:, persistent_account_id:)
      Plaid::AccountBase.new(
        account_id: account_id,
        persistent_account_id: persistent_account_id,
        name: "Plaid Depository Account",
        mask: "0000",
        type: "depository",
        subtype: "checking",
        balances: Plaid::AccountBalance.new(current: 1000, available: 1000, iso_currency_code: "USD")
      )
    end

    def duplicate_plaid_account(plaid_id:, persistent_account_id:)
      @plaid_item.plaid_accounts.create!(
        plaid_id: plaid_id,
        name: "Plaid Depository Account",
        plaid_type: "depository",
        currency: "USD",
        current_balance: 1000,
        raw_payload: { "account_id" => plaid_id, "persistent_account_id" => persistent_account_id }
      )
    end

    def stub_accounts_snapshot(*raw_accounts)
      PlaidItem::AccountsSnapshot.any_instance.stubs(:accounts).returns(raw_accounts)
      raw_accounts.each do |raw_account|
        PlaidItem::AccountsSnapshot.any_instance.stubs(:get_account_data).with(raw_account.account_id).returns(
          PlaidItem::AccountsSnapshot::AccountData.new(
            account_data: raw_account,
            transactions_data: nil,
            investments_data: nil,
            liabilities_data: nil
          )
        )
      end
      PlaidItem::AccountsSnapshot.any_instance.stubs(:transactions_cursor).returns("test_cursor_1")
      @importer.stubs(:fetch_and_import_item_data)
    end
end
