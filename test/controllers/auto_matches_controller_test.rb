require "test_helper"

class AutoMatchesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
  end

  test "index lists pending auto-matched transfers for the family" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: accounts(:credit_card), amount: -500)
    @family.auto_match_transfers!

    get auto_matches_url
    assert_response :success
    assert_select "tr##{ActionView::RecordIdentifier.dom_id(outflow_entry.transaction.transfer)}"
  end

  test "index does not include transfers already confirmed" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: accounts(:credit_card), amount: -500)
    @family.auto_match_transfers!
    outflow_entry.transaction.transfer.confirm!

    get auto_matches_url
    assert_response :success
    assert_select "tr##{ActionView::RecordIdentifier.dom_id(outflow_entry.transaction.transfer)}", false
  end

  test "index excludes matches where the outflow account is private to another family member" do
    # other_asset is owned by family_admin and not shared with family_member;
    # depository is shared with family_member (full_control).
    outflow_entry = create_transaction(date: Date.current, account: accounts(:other_asset), amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: -500)
    @family.auto_match_transfers!

    sign_in users(:family_member)
    get auto_matches_url
    assert_response :success
    assert_select "tr##{ActionView::RecordIdentifier.dom_id(outflow_entry.transaction.transfer)}", false
  end

  # Regression: the bulk-select <form> used to wrap the whole table,
  # including each row's own Confirm/Reject button_to form. Nested <form>
  # elements are invalid HTML -- browsers flatten them, which merged every
  # row's authenticity_token into the outer form and made clicking an
  # individual Confirm/Reject button submit the *bulk* form instead,
  # raising ActionController::InvalidAuthenticityToken in production.
  test "index does not nest the per-row confirm/reject forms inside the bulk-select form" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: accounts(:credit_card), amount: -500)
    @family.auto_match_transfers!

    get auto_matches_url
    assert_response :success

    doc = Nokogiri::HTML::Document.parse(response.body)
    bulk_form = doc.at_css("form[action='#{bulk_update_auto_matches_path}']")
    assert_not_nil bulk_form
    assert_empty bulk_form.css("form"), "no <form> should be nested inside the bulk-update form"

    row = doc.at_css("tr##{ActionView::RecordIdentifier.dom_id(outflow_entry.transaction.transfer)}")
    row_forms = row.css("form")
    assert_equal 2, row_forms.size, "expected the row's own confirm and reject forms"
    assert row_forms.all? { |f| f["action"].start_with?(transfer_path(outflow_entry.transaction.transfer)) },
      "the per-row confirm/reject forms should still target the transfer"
  end

  test "update_settings disables auto match" do
    patch update_settings_auto_matches_url, params: { auto_match_transfers_disabled: "true" }
    assert_redirected_to auto_matches_url
    assert @family.reload.auto_match_transfers_disabled?
  end

  test "update_settings re-enables auto match" do
    @family.update!(auto_match_transfers_disabled: true)

    patch update_settings_auto_matches_url, params: { auto_match_transfers_disabled: "false" }
    assert_redirected_to auto_matches_url
    assert_not @family.reload.auto_match_transfers_disabled?
  end

  test "update_settings enqueues an immediate match scan when re-enabling" do
    @family.update!(auto_match_transfers_disabled: true)

    assert_enqueued_with(job: AutoMatchTransfersJob, args: [ @family ]) do
      patch update_settings_auto_matches_url, params: { auto_match_transfers_disabled: "false" }
    end
  end

  test "update_settings does not enqueue a match scan when disabling" do
    assert_no_enqueued_jobs(only: AutoMatchTransfersJob) do
      patch update_settings_auto_matches_url, params: { auto_match_transfers_disabled: "true" }
    end
  end

  test "update_settings does not enqueue a match scan when the setting doesn't change" do
    assert_no_enqueued_jobs(only: AutoMatchTransfersJob) do
      patch update_settings_auto_matches_url, params: { auto_match_transfers_disabled: "false" }
    end
  end

  # Regression for jjmata's round-3 finding: cleanup_pending_auto_matches!
  # used to match every Transfer.pending for the family, so disabling the
  # toggle would destroy (and thereby kind-reset, see Transfer#destroy!) a
  # pending transfer that arrived with a kind already set by an import path
  # (Family::DataImporter, Demo::Generator) -- not a genuine auto-match
  # suggestion.
  test "update_settings disabling destroys genuine pending auto-matches but preserves imported pending transfers with a kind already set" do
    genuine_outflow = create_transaction(date: Date.current, account: accounts(:depository), amount: 500, kind: "standard")
    genuine_inflow = create_transaction(date: Date.current, account: accounts(:credit_card), amount: -500, kind: "standard")
    @family.auto_match_transfers!
    genuine_transfer = genuine_outflow.transaction.reload.transfer
    assert genuine_transfer.present? && genuine_transfer.pending?

    imported_outflow = create_transaction(date: Date.current, account: accounts(:depository), amount: 700, kind: "investment_contribution")
    imported_inflow = create_transaction(date: Date.current, account: accounts(:credit_card), amount: -700, kind: "funds_movement")
    imported_transfer = Transfer.create!(inflow_transaction: imported_inflow.transaction, outflow_transaction: imported_outflow.transaction)
    assert imported_transfer.pending?

    patch update_settings_auto_matches_url, params: { auto_match_transfers_disabled: "true" }

    assert_not Transfer.exists?(genuine_transfer.id)
    assert Transfer.exists?(imported_transfer.id)
    assert_equal "investment_contribution", imported_outflow.transaction.reload.kind
    assert_equal "funds_movement", imported_inflow.transaction.reload.kind
  end
end
