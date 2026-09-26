require "test_helper"
require_relative "../support/financekit_test_helper"

class FinancekitAccountsTest < ActionDispatch::IntegrationTest
  include FinancekitTestHelper
  include ActionView::RecordIdentifier

  setup do
    ensure_tailwind_build
    financekit_setup(user: users(:empty))
    sign_in @user
  end

  test "a family with only FinanceKit accounts sees them on the accounts index" do
    get accounts_url

    assert_response :success
    assert_select "#financekit-accounts" do
      assert_select "summary", text: /Apple Wallet/
      assert_select "a[href=?][data-turbo-frame='_top']", account_path(@source.account), text: "Test Wallet"
      assert_select "turbo-frame##{dom_id(@source.account)}"
    end
    assert_select "#manual-accounts a[href=?]", account_path(@source.account), count: 0
  end

  test "FinanceKit account detail renders imported transactions" do
    accept_and_apply

    get account_url(@source.account)

    assert_response :success
    assert_select "header h2", text: "Test Wallet"
    assert_includes response.body, "Synthetic shop"
  end

  test "Wallet accounts can unlink and reconnect from a fresh client enrollment" do
    accept_and_apply
    account = @source.account
    entry = account.entries.sole
    lineage = @source.financekit_account_lineage
    old_stream = @item.reload.stream_id
    queued, = accept_batch(financekit_payload(sequence: @item.next_sequence,
      predecessor_digest: @item.predecessor_digest))

    get accounts_url
    assert_response :success
    assert_select "a[href=?]", confirm_unlink_account_path(account)

    get confirm_unlink_account_url(account)
    assert_response :success
    assert_includes response.body, I18n.t("accounts.confirm_unlink.warning_wallet_connection")

    assert_no_difference [ "Account.count", "Entry.count", "FinancekitAccount.count", "FinancekitTransaction.count" ] do
      delete unlink_account_url(account)
    end
    assert_redirected_to accounts_url
    assert_not account.reload.linked?
    assert_equal "revoked", @item.reload.status
    assert_not @item.authenticate_credential?(@credential)
    assert_equal "revoked", queued.reload.status
    assert_equal "connection_revoked", queued.error_code
    assert_nil queued.payload
    assert_not Financekit::Processor.new(@item).apply_next!
    error = assert_raises(Financekit::Error) { accept_batch }
    assert_equal "connection_revoked", error.code

    get accounts_url
    assert_select "#manual-accounts a[href=?]", account_path(account)
    get account_url(account)
    assert_response :success
    assert_includes response.body, "Synthetic shop"

    # A reset Swift client knows only its stable Apple source IDs, not the old
    # connection, lineage, mapping version, stream or sequence.
    fresh = Financekit::Enrollment.create!(@user, @enrollment.merge("enrollment_id" => SecureRandom.uuid)).item
    assert_no_difference [ "Account.count", "FinancekitAccountLineage.count" ] do
      @source = FinancekitAccount.map!(fresh, @source_id, @mapping_input)
    end
    assert_equal account, @source.account
    assert_equal lineage, @source.financekit_account_lineage
    assert_equal 2, @source.mapping_version
    credential = fresh.activate!
    assert fresh.authenticate_credential?(credential)
    assert_not_equal old_stream, fresh.stream_id
    assert_equal 1, fresh.next_sequence
    assert_nil fresh.predecessor_digest
    assert account.reload.linked?

    assert_no_difference "Entry.count" do
      accept_and_apply(financekit_payload(item: fresh), item: fresh)
    end
    assert_equal [ entry.id ], account.entries.reload.pluck(:id)

    events = financekit_events
    events.last["transaction"]["source_id"] = SecureRandom.uuid
    events.last["transaction"]["transaction_description"] = "New purchase after reconnect"
    events.last["transaction"]["merchant_name"] = "New purchase after reconnect"
    fresh.reload
    assert_difference "Entry.count", 1 do
      accept_and_apply(financekit_payload(item: fresh, sequence: fresh.next_sequence,
        predecessor_digest: fresh.predecessor_digest, events: events), item: fresh)
    end
    assert account.entries.exists?(name: "New purchase after reconnect")
  end

  test "unlink disconnects all accounts sharing the publisher even when it needs repair" do
    second_source = SecureRandom.uuid
    @item.update!(status: "repair_required", consent: @item.consent.merge(
      "selected_source_account_ids" => [ @source_id, second_source ]))
    second_mapping = FinancekitAccount.map!(@item, second_source, @mapping_input.merge("name" => "Apple Cash"))
    @item.activate!
    @item.mark_repair!("test_failure")

    delete unlink_account_url(@source.account)

    assert_redirected_to accounts_url
    assert_not @source.account.reload.linked?
    assert_not second_mapping.account.reload.linked?
    assert_equal "revoked", @item.reload.status
    error = assert_raises(Financekit::Error) { @item.repair! }
    assert_equal "connection_revoked", error.code
  end

  test "read only sharing and another family cannot disconnect a Wallet publisher" do
    account = @source.account
    viewer = users(:new_email)
    account.account_shares.find_or_initialize_by(user: viewer).update!(permission: "read_only")
    sign_in viewer

    delete unlink_account_url(account)
    assert_redirected_to account_url(account)
    assert_equal "active", @item.reload.status
    assert account.reload.linked?

    sign_in users(:family_admin)
    delete unlink_account_url(account)
    assert_response :not_found
    assert_equal "active", @item.reload.status
    assert account.reload.linked?
  end

  test "failed unlink rolls back the Wallet revocation and provider links" do
    queued, = accept_batch
    Account.any_instance.stubs(:update!).raises(ActiveRecord::RecordInvalid.new(@source.account))

    delete unlink_account_url(@source.account)

    assert_redirected_to account_url(@source.account)
    assert_equal "active", @item.reload.status
    assert @item.authenticate_credential?(@credential)
    assert @source.account.reload.linked?
    assert_equal "accepted", queued.reload.status
    assert queued.payload.present?
  end

  test "index shows disabled Wallet accounts but excludes pending deletion" do
    @source.account.update!(status: "disabled")
    get accounts_url
    assert_response :success
    assert_select "#financekit-accounts a[href=?]", account_path(@source.account)

    @source.account.update!(status: "pending_deletion")
    get accounts_url
    assert_response :success
    assert_select "#financekit-accounts", count: 0
  end

  test "index limits Wallet accounts to the viewer's owned and shared accounts" do
    private_source_id = SecureRandom.uuid
    @item.update!(status: "repair_required", consent: @item.consent.merge(
      "selected_source_account_ids" => [ @source_id, private_source_id ]))
    private_mapping = FinancekitAccount.map!(@item, private_source_id, @mapping_input.merge("name" => "Private Wallet"))
    @item.activate!
    shared = @source.account
    [ shared, private_mapping.account ].each { |account| account.account_shares.destroy_all }
    viewer = users(:new_email)
    assert_equal @family, viewer.family
    shared.account_shares.create!(user: viewer, permission: "read_only")

    sign_in viewer
    get accounts_url

    assert_response :success
    assert_select "#financekit-accounts a[href=?]", account_path(shared)
    assert_select "#financekit-accounts a[href=?]", account_path(private_mapping.account), count: 0
    assert_not_includes response.body, "Private Wallet"

    sign_in users(:family_admin)
    get accounts_url
    assert_response :success
    assert_select "#financekit-accounts", count: 0
  end
end
