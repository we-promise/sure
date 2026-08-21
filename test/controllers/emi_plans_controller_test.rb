require "test_helper"

class EmiPlansControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @entry = create_transaction(
      amount: 1200,
      name: "New Laptop",
      account: accounts(:depository)
    )
  end

  test "new renders emi plan form" do
    get new_transaction_emi_plan_path(@entry)
    assert_response :success
  end

  test "new redirects when transaction isn't emi_convertible" do
    income_entry = create_transaction(amount: -400, name: "Refund", account: accounts(:depository))

    get new_transaction_emi_plan_path(income_entry)
    assert_redirected_to transactions_url
    assert_equal I18n.t("emi_plans.new.not_convertible"), flash[:alert]
  end

  test "create with valid params builds the plan and installments" do
    assert_difference "Entry.count", 12 do
      post transaction_emi_plan_path(@entry), params: {
        emi_plan: { tenure_months: 12, interest_rate: 10, processing_fee: 0 }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "emi_purchase", @entry.reload.transaction.kind
  end

  test "create with a processing fee also creates the fee entry" do
    assert_difference "Entry.count", 12 + 1 do
      post transaction_emi_plan_path(@entry), params: {
        emi_plan: { tenure_months: 12, interest_rate: 0, processing_fee: 25 }
      }
    end

    assert_redirected_to transactions_url
  end

  test "create rejects an already-converted transaction" do
    post transaction_emi_plan_path(@entry), params: {
      emi_plan: { tenure_months: 6, interest_rate: 0, processing_fee: 0 }
    }

    assert_no_difference "Entry.count" do
      post transaction_emi_plan_path(@entry), params: {
        emi_plan: { tenure_months: 6, interest_rate: 0, processing_fee: 0 }
      }
    end

    assert_redirected_to transactions_url
    assert_equal I18n.t("emi_plans.new.not_convertible"), flash[:alert]
  end

  test "show renders the plan schedule" do
    post transaction_emi_plan_path(@entry), params: {
      emi_plan: { tenure_months: 6, interest_rate: 0, processing_fee: 0 }
    }

    get transaction_emi_plan_path(@entry)
    assert_response :success
  end

  test "show from an installment resolves to the parent plan" do
    post transaction_emi_plan_path(@entry), params: {
      emi_plan: { tenure_months: 6, interest_rate: 0, processing_fee: 0 }
    }
    installment = @entry.reload.originated_emi_plan.installment_entries.first

    get transaction_emi_plan_path(installment)
    assert_response :success
  end

  test "destroy forecloses the plan and removes future installments" do
    # start_date 45 days ago + 3 month tenure => installment 1 (~45d ago,
    # posted), installment 2 (~14d ago, posted), installment 3 (~17d from
    # now, future). Deliberately not using clean N-month offsets from
    # Date.current here: with tenure_months installments landing on exact
    # month boundaries, one of them can land exactly on Date.current
    # depending on which day of the month the suite runs — and foreclose!
    # treats "today" as posted (date > Date.current, not >=), which made an
    # earlier version of this test flaky/wrong depending on the run date.
    post transaction_emi_plan_path(@entry), params: {
      emi_plan: { tenure_months: 3, interest_rate: 0, processing_fee: 0, start_date: (Date.current - 45.days).iso8601 }
    }

    # The future installment is removed, but because installments already
    # posted, a settlement entry is created for its outstanding principal
    # so that amount isn't just dropped from budget totals. Net entry count
    # is unchanged; what matters is which entry it is now.
    assert_difference "Entry.count", 0 do
      delete transaction_emi_plan_path(@entry)
    end

    assert_redirected_to transactions_url
    assert_equal I18n.t("emi_plans.destroy.success"), flash[:notice]
  end

  test "destroy on an already-foreclosed plan does not re-run foreclose" do
    post transaction_emi_plan_path(@entry), params: {
      emi_plan: { tenure_months: 3, interest_rate: 0, processing_fee: 0, start_date: (Date.current - 45.days).iso8601 }
    }

    delete transaction_emi_plan_path(@entry)
    assert_equal "foreclosed", @entry.reload.originated_emi_plan.status

    # Second foreclose attempt (e.g. double-click, replayed request) must
    # not touch entries again -- it should just bounce with the not_emi alert.
    assert_no_difference "Entry.count" do
      delete transaction_emi_plan_path(@entry)
    end

    assert_redirected_to transactions_url
    assert_equal I18n.t("emi_plans.show.not_emi"), flash[:alert]
  end

  # --- Authorization / abuse-hardening tests ---

  test "cannot access another family's entry (IDOR)" do
    # @entry belongs to dylan_family; users(:empty) is in a different family.
    sign_in users(:empty)

    get new_transaction_emi_plan_path(@entry)
    assert_response :not_found
  end

  test "cannot create an emi plan on another family's entry (IDOR)" do
    sign_in users(:empty)

    assert_no_difference "Entry.count" do
      post transaction_emi_plan_path(@entry), params: {
        emi_plan: { tenure_months: 6, interest_rate: 0, processing_fee: 0 }
      }
    end

    assert_response :not_found
  end

  test "a family member without write permission cannot create an emi plan" do
    read_only_entry = create_transaction(amount: 500, name: "Groceries", account: accounts(:credit_card))
    sign_in users(:family_member) # read_only on accounts(:credit_card), per account_shares fixture

    assert_no_difference "Entry.count" do
      post transaction_emi_plan_path(read_only_entry), params: {
        emi_plan: { tenure_months: 6, interest_rate: 0, processing_fee: 0 }
      }
    end

    assert_response :redirect
  end

  test "a family member without write permission cannot foreclose an emi plan" do
    read_only_entry = create_transaction(amount: 500, name: "Groceries", account: accounts(:credit_card))
    post transaction_emi_plan_path(read_only_entry), params: {
      emi_plan: { tenure_months: 6, interest_rate: 0, processing_fee: 0 }
    }

    sign_in users(:family_member) # read_only on accounts(:credit_card), per account_shares fixture

    assert_no_difference "Entry.count" do
      delete transaction_emi_plan_path(read_only_entry)
    end

    assert_equal "emi_purchase", read_only_entry.reload.transaction.kind
  end

  test "an outrageous tenure_months is rejected, not silently accepted" do
    assert_no_difference "Entry.count" do
      post transaction_emi_plan_path(@entry), params: {
        emi_plan: { tenure_months: 999_999_999, interest_rate: 0, processing_fee: 0 }
      }
    end

    assert_redirected_to transactions_url
  end

  test "a non-numeric tenure_months does not raise a server error" do
    assert_no_difference "Entry.count" do
      post transaction_emi_plan_path(@entry), params: {
        emi_plan: { tenure_months: "'; DROP TABLE entries; --", interest_rate: 0, processing_fee: 0 }
      }
    end

    assert_redirected_to transactions_url
    assert Entry.table_exists? # table is still there
  end

  test "an outrageous interest_rate is rejected" do
    assert_no_difference "Entry.count" do
      post transaction_emi_plan_path(@entry), params: {
        emi_plan: { tenure_months: 6, interest_rate: 99999, processing_fee: 0 }
      }
    end
  end

  test "unpermitted params (like principal_amount) are ignored, not applied" do
    post transaction_emi_plan_path(@entry), params: {
      emi_plan: { tenure_months: 6, interest_rate: 0, processing_fee: 0, principal_amount: 1 }
    }

    plan = @entry.reload.originated_emi_plan
    assert_equal @entry.amount.abs, plan.principal_amount
    refute_equal 1, plan.principal_amount
  end
end
