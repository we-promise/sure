require "test_helper"

class TransferMatchesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
  end

  test "matches existing transaction and creates transfer" do
    inflow_transaction = create_transaction(amount: 100, account: accounts(:depository))
    outflow_transaction = create_transaction(amount: -100, account: accounts(:investment))

    assert_difference "Transfer.count", 1 do
      post transaction_transfer_match_path(inflow_transaction), params: {
        transfer_match: {
          method: "existing",
          matched_entry_id: outflow_transaction.id
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "Transfer created", flash[:notice]
  end

  test "creates transfer for target account" do
    inflow_transaction = create_transaction(amount: 100, account: accounts(:depository))

    assert_difference [ "Transfer.count", "Entry.count", "Transaction.count" ], 1 do
      post transaction_transfer_match_path(inflow_transaction), params: {
        transfer_match: {
          method: "new",
          target_account_id: accounts(:investment).id
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "Transfer created", flash[:notice]
  end

  test "new transfer entry is protected from provider sync" do
    outflow_entry = create_transaction(amount: 100, account: accounts(:depository))

    post transaction_transfer_match_path(outflow_entry), params: {
      transfer_match: {
        method: "new",
        target_account_id: accounts(:investment).id
      }
    }

    transfer = Transfer.order(created_at: :desc).first
    new_entry = transfer.inflow_transaction.entry

    assert new_entry.user_modified?, "New transfer entry should be marked as user_modified to protect from provider sync"
  end

  test "assigns investment_contribution kind and category for investment destination" do
    # Outflow from depository (positive amount), target is investment
    outflow_entry = create_transaction(amount: 100, account: accounts(:depository))

    post transaction_transfer_match_path(outflow_entry), params: {
      transfer_match: {
        method: "new",
        target_account_id: accounts(:investment).id
      }
    }

    outflow_entry.reload
    outflow_txn = outflow_entry.entryable

    assert_equal "investment_contribution", outflow_txn.kind

    category = @user.family.investment_contributions_category
    assert_equal category, outflow_txn.category
  end

  test "new pre-selects a target account when the counterparty iban matches another account" do
    target_account = accounts(:investment)
    target_account.update!(iban: "DE89370400440532013000") # pipelock:ignore IBAN

    outflow_entry = create_transaction(amount: 100, account: accounts(:depository))
    outflow_entry.entryable.update!(extra: { "counterparty_iban" => "DE89 3704 0044 0532 0130 00" })

    get new_transaction_transfer_match_path(outflow_entry)

    assert_response :success
    assert_select "option[selected][value=?]", target_account.id
    assert_match target_account.name, response.body
  end

  test "new does not suggest an account when no iban matches" do
    outflow_entry = create_transaction(amount: 100, account: accounts(:depository))
    outflow_entry.entryable.update!(extra: { "counterparty_iban" => "AT611904300234573201" }) # pipelock:ignore IBAN

    get new_transaction_transfer_match_path(outflow_entry)

    assert_response :success
    assert_no_match I18n.t("transfer_matches.matching_fields.dismiss_suggestion"), response.body
  end

  test "new does not suggest an account once a real transfer candidate exists" do
    target_account = accounts(:investment)
    target_account.update!(iban: "DE89370400440532013000") # pipelock:ignore IBAN

    outflow_entry = create_transaction(amount: 100, account: accounts(:depository))
    outflow_entry.entryable.update!(extra: { "counterparty_iban" => "DE89370400440532013000" }) # pipelock:ignore IBAN
    # A real matching inflow already exists on the target account, so this
    # is a normal match, not a "missing counterpart" situation.
    create_transaction(amount: -100, account: target_account)

    get new_transaction_transfer_match_path(outflow_entry)

    assert_response :success
    assert_no_match I18n.t("transfer_matches.matching_fields.dismiss_suggestion"), response.body
  end

  test "dismiss_suggestion marks the suggestion dismissed and it does not reappear" do
    target_account = accounts(:investment)
    target_account.update!(iban: "DE89370400440532013000") # pipelock:ignore IBAN

    outflow_entry = create_transaction(amount: 100, account: accounts(:depository))
    outflow_entry.entryable.update!(extra: { "counterparty_iban" => "DE89370400440532013000" }) # pipelock:ignore IBAN

    post dismiss_suggestion_transaction_transfer_match_path(outflow_entry)

    assert_redirected_to transactions_url
    assert outflow_entry.entryable.reload.extra["counterparty_transfer_suggestion_dismissed"]

    get new_transaction_transfer_match_path(outflow_entry)
    assert_no_match I18n.t("transfer_matches.matching_fields.dismiss_suggestion"), response.body
  end
end
