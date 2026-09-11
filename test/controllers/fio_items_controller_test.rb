require "test_helper"

class FioItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)

    @family = families(:dylan_family)
    @fio_item = fio_items(:one)
    @fio_account = fio_accounts(:checking)
  end

  test "create saves the connection and starts a sync" do
    # The setup-wide stub allows zero calls, so the enqueue is asserted explicitly here:
    # a regression that stops kicking off the first sync would otherwise pass.
    SyncJob.expects(:perform_later).with { |sync| sync.syncable.is_a?(FioItem) }.once

    assert_difference "FioItem.count", 1 do
      post fio_items_url, params: {
        fio_item: { name: "Savings", token: " second-token ", sync_start_date: "2026-01-01" }
      }
    end

    assert_redirected_to settings_providers_path

    created = FioItem.order(:created_at).last
    assert_equal "second-token", created.token
    assert_equal "Savings", created.name
    assert_equal Date.new(2026, 1, 1), created.sync_start_date
    assert_equal 1, created.syncs.count
  end

  test "create rejects a blank token" do
    assert_no_difference "FioItem.count" do
      post fio_items_url, params: { fio_item: { name: "No token", token: "   " } }
    end

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("fio_items.create.token_required"), flash[:alert]
  end

  # The form sets the status, so only a sync can establish whether Fio accepts the new
  # token — without one the connection would claim to be healthy on the user's word.
  test "update rotates the token, clears requires_update and revalidates it" do
    @fio_item.update!(status: :requires_update)
    SyncJob.expects(:perform_later).with { |sync| sync.syncable == @fio_item }.once

    patch fio_item_url(@fio_item), params: {
      fio_item: { name: "Rotated", token: "fresh-token" }
    }

    @fio_item.reload
    assert_equal "fresh-token", @fio_item.token
    assert_equal "Rotated", @fio_item.name
    assert @fio_item.good?
  end

  test "update keeps the existing token when the field is left blank" do
    patch fio_item_url(@fio_item), params: {
      fio_item: { name: "Renamed", token: "" }
    }

    @fio_item.reload
    assert_equal "Renamed", @fio_item.name
    assert_equal "fio-test-token", @fio_item.token
  end

  test "sync enqueues a sync for the connection" do
    SyncJob.expects(:perform_later).with { |sync| sync.syncable == @fio_item }.once

    post sync_fio_item_url(@fio_item)

    assert_redirected_to accounts_path
  end

  test "destroy unlinks the account and schedules the connection for deletion" do
    @fio_account.ensure_account_provider!(accounts(:depository))
    DestroyJob.expects(:perform_later).with(@fio_item).once

    delete fio_item_url(@fio_item)

    assert_redirected_to settings_providers_path
    assert @fio_item.reload.scheduled_for_deletion?
    assert_nil @fio_account.reload.account_provider
  end

  test "link_accounts creates a checking account for the connection's single account" do
    assert_difference [ "Account.count", "AccountProvider.count" ], 1 do
      post link_accounts_fio_items_url, params: {
        fio_item_id: @fio_item.id, accountable_type: "Depository"
      }
    end

    assert_redirected_to accounts_path

    account = @fio_account.reload.current_account
    assert_equal "Depository", account.accountable_type
    assert_equal "checking", account.accountable.subtype
    assert_equal "CZK", account.currency
    assert_equal @fio_account.current_balance, account.balance
  end

  test "link_accounts honours a user-chosen account type" do
    post link_accounts_fio_items_url, params: {
      fio_item_id: @fio_item.id, accountable_type: "Loan"
    }

    account = @fio_account.reload.current_account
    assert_equal "Loan", account.accountable_type
  end

  test "link_accounts refuses an unsupported account type" do
    assert_no_difference "Account.count" do
      post link_accounts_fio_items_url, params: {
        fio_item_id: @fio_item.id, accountable_type: "Crypto"
      }
    end

    assert_redirected_to new_account_path
  end

  test "link_existing_account links the Fio account to an account the user already has" do
    account = accounts(:depository)

    assert_difference "AccountProvider.count", 1 do
      post link_existing_account_fio_items_url, params: {
        fio_item_id: @fio_item.id, account_id: account.id, fio_account_id: @fio_account.id
      }
    end

    assert_redirected_to accounts_path
    assert_equal account, @fio_account.reload.current_account
  end

  test "complete_account_setup skips the account so it stops asking" do
    assert_no_difference "Account.count" do
      post complete_account_setup_fio_item_url(@fio_item), params: { account_type: "skip" }
    end

    assert_redirected_to accounts_path
    assert @fio_account.reload.ignored?
    assert_empty @fio_item.fio_accounts.needs_setup
  end

  test "complete_account_setup creates the chosen account type" do
    assert_difference [ "Account.count", "AccountProvider.count" ], 1 do
      post complete_account_setup_fio_item_url(@fio_item), params: { account_type: "Loan" }
    end

    assert_redirected_to accounts_path
    assert_equal "Loan", @fio_account.reload.current_account.accountable_type
  end

  # Fio only reveals the account a token reaches inside a statement, so the setup screen
  # has to cope with the first sync not having run (or having run over an empty window).
  test "setup_accounts offers a sync when no account has been reported yet" do
    @fio_account.destroy!

    get setup_accounts_fio_item_url(@fio_item)

    assert_response :success
    assert_select "body", text: /#{Regexp.escape(I18n.t("fio_items.setup_accounts.awaiting_first_sync"))}/
  end

  test "setup_accounts offers the discovered account with a preselected type" do
    get setup_accounts_fio_item_url(@fio_item)

    assert_response :success
    selected_option = css_select("select[name='account_type'] option[selected='selected']").first
    assert_equal "Depository", selected_option["value"]
  end
end
