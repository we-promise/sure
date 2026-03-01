require "test_helper"

class PendingDuplicateMergesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "new displays pending transaction and candidate posted transactions" do
    pending_transaction = create_pending_transaction(amount: -50, account: @account)
    posted_transaction = create_transaction(amount: -50, account: @account)

    get new_transaction_pending_duplicate_merges_path(pending_transaction)

    assert_response :success
  end

  test "new redirects if transaction is not pending" do
    posted_transaction = create_transaction(amount: -50, account: @account)

    get new_transaction_pending_duplicate_merges_path(posted_transaction)

    assert_redirected_to transactions_path
    assert_equal "This feature is only available for pending transactions", flash[:alert]
  end

  test "create merges pending transaction with selected posted transaction" do
    pending_transaction = create_pending_transaction(amount: -50, account: @account)
    posted_transaction = create_transaction(amount: -50, account: @account)

    assert_difference "Entry.count", -1 do
      post transaction_pending_duplicate_merges_path(pending_transaction), params: {
        pending_duplicate_merges: {
          posted_entry_id: posted_transaction.id
        }
      }
    end

    assert_redirected_to transactions_path
    assert_equal "Pending transaction merged with posted transaction", flash[:notice]
    assert_nil Entry.find_by(id: pending_transaction.id), "Pending entry should be deleted after merge"
  end

  test "create redirects back to referer after successful merge" do
    pending_transaction = create_pending_transaction(amount: -50, account: @account)
    posted_transaction = create_transaction(amount: -50, account: @account)

    assert_difference "Entry.count", -1 do
      post transaction_pending_duplicate_merges_path(pending_transaction),
        params: {
          pending_duplicate_merges: {
            posted_entry_id: posted_transaction.id
          }
        },
        headers: { "HTTP_REFERER" => account_path(@account) }
    end

    assert_redirected_to account_path(@account)
    assert_equal "Pending transaction merged with posted transaction", flash[:notice]
  end

  test "create redirects with error if no posted entry selected" do
    pending_transaction = create_pending_transaction(amount: -50, account: @account)

    post transaction_pending_duplicate_merges_path(pending_transaction), params: {
      pending_duplicate_merges: {
        posted_entry_id: ""
      }
    }

    assert_redirected_to transactions_path
    assert_equal "Please select a posted transaction to merge with", flash[:alert]
  end

  test "create stores potential_posted_match metadata before merging" do
    pending_transaction = create_pending_transaction(amount: -50, account: @account)
    posted_transaction = create_transaction(amount: -50, account: @account)

    # Stub merge to prevent deletion so we can check metadata
    Transaction.any_instance.stubs(:merge_with_duplicate!).returns(true)

    post transaction_pending_duplicate_merges_path(pending_transaction), params: {
      pending_duplicate_merges: {
        posted_entry_id: posted_transaction.id
      }
    }

    pending_transaction.reload
    metadata = pending_transaction.entryable.extra["potential_posted_match"]
    
    assert_not_nil metadata
    assert_equal posted_transaction.id, metadata["entry_id"]
    assert_equal "manual_match", metadata["reason"]
    assert_equal posted_transaction.amount.to_s, metadata["posted_amount"]
    assert_equal "high", metadata["confidence"]
    assert_equal Date.current.to_s, metadata["detected_at"]
  end

  test "pending_duplicate_candidates excludes pending transactions" do
    pending_transaction = create_pending_transaction(amount: -50, account: @account)
    posted_transaction = create_transaction(amount: -50, account: @account)
    another_pending = create_pending_transaction(amount: -40, account: @account)

    candidates = pending_transaction.entryable.pending_duplicate_candidates

    assert_includes candidates.map(&:id), posted_transaction.id
    assert_not_includes candidates.map(&:id), another_pending.id
  end

  test "pending_duplicate_candidates only shows same account and currency" do
    pending_transaction = create_pending_transaction(amount: -50, account: @account, currency: "USD")
    same_account_transaction = create_transaction(amount: -50, account: @account, currency: "USD")
    different_account_transaction = create_transaction(amount: -50, account: accounts(:investment), currency: "USD")
    different_currency_transaction = create_transaction(amount: -50, account: @account, currency: "EUR")

    candidates = pending_transaction.entryable.pending_duplicate_candidates

    assert_includes candidates.map(&:id), same_account_transaction.id
    assert_not_includes candidates.map(&:id), different_account_transaction.id
    assert_not_includes candidates.map(&:id), different_currency_transaction.id
  end

  private

  def create_pending_transaction(attributes = {})
    # Create a transaction with pending metadata
    transaction = create_transaction(attributes)
    
    # Mark it as pending by adding extra metadata
    transaction.entryable.update!(
      extra: {
        "simplefin" => {
          "pending" => true
        }
      }
    )
    
    transaction
  end
end
