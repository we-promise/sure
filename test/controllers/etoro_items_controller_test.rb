require "test_helper"

class EtoroItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @item = etoro_items(:configured_item)
    @etoro_account = etoro_accounts(:main_account)
  end

  test "create saves both keys and starts a sync" do
    assert_difference "EtoroItem.count", 1 do
      post etoro_items_url, params: { etoro_item: { api_key: "new_public_key", user_key: "new_user_key" } }
    end

    item = EtoroItem.order(:created_at).last
    assert_redirected_to accounts_path
    assert_equal "new_user_key", item.user_key
    assert_equal I18n.t("settings.providers.etoro_panel.default_account_name"), item.name
    assert_enqueued_with(job: SyncJob, args: [ item.syncs.sole ])
  end

  test "create without a user key is rejected" do
    assert_no_difference "EtoroItem.count" do
      post etoro_items_url, params: { etoro_item: { api_key: "new_public_key", user_key: "" } }
    end
  end

  test "create saves the own securities preference" do
    post etoro_items_url, params: { etoro_item: { api_key: "new_public_key", user_key: "new_user_key", own_securities: "1" } }

    assert EtoroItem.order(:created_at).last.own_securities?
  end

  test "update saves the own securities preference, keeps the keys and syncs the connection" do
    assert_not @item.own_securities?

    assert_enqueued_with(job: SyncJob) do
      patch etoro_item_url(@item), params: { etoro_item: { api_key: "", user_key: "", own_securities: "1" } }
    end

    @item.reload
    assert @item.own_securities?
    assert_equal [ "test_public_key", "test_user_key" ], [ @item.api_key, @item.user_key ]
  end

  test "the panel offers the own securities preference for each connection and for a new one" do
    @item.update!(own_securities: true)
    connections = @item.family.etoro_items.count

    post sync_etoro_item_url(@item, source: "panel"), as: :turbo_stream

    assert_select "input[type=checkbox][name='etoro_item[own_securities]'][checked]", count: 1
    assert_select "input[type=checkbox][name='etoro_item[own_securities]']:not([checked])", count: connections
    assert_select "label", text: I18n.t("settings.providers.etoro_panel.own_securities_label"), count: connections + 1
  end

  test "update keeps keys left blank" do
    patch etoro_item_url(@item), params: { etoro_item: { api_key: "rotated_public_key", user_key: "" } }

    @item.reload
    assert_equal "rotated_public_key", @item.api_key
    assert_equal "test_user_key", @item.user_key
  end

  test "new keys put a connection that needs attention back in good standing and sync it" do
    @item.update!(status: :requires_update)

    assert_enqueued_with(job: SyncJob) do
      patch etoro_item_url(@item), params: { etoro_item: { api_key: "rotated_public_key", user_key: "" } }
    end

    assert @item.reload.good?
  end

  test "complete account setup creates a linked investment account" do
    EtoroAccount::Processor.any_instance.stubs(:process)

    assert_difference "Account.count", 1 do
      post complete_account_setup_etoro_item_url(@item), params: { account_ids: [ @etoro_account.id ] }
    end

    assert_redirected_to accounts_path
    account = @etoro_account.reload.current_account
    assert_equal "Investment", account.accountable_type
    assert_equal "USD", account.currency
  end

  test "accounts page shows the connection card, with the sync frequency entry in its menu" do
    get accounts_url

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(@item)}"
    assert_select "a[href=?]", edit_sync_schedule_path(syncable_type: "EtoroItem", syncable_id: @item.id), text: I18n.t("sync_schedules.menu_item")
  end

  test "setup accounts lists the discovered account" do
    get setup_accounts_etoro_item_url(@item)

    assert_response :success
    assert_select "input[name='account_ids[]'][value=?]", @etoro_account.id
  end

  test "the setup page fetches itself again while a sync is still discovering the accounts" do
    get setup_accounts_etoro_item_url(@item)

    assert_response :success
    assert_select "[data-controller=polling]", count: 0
    assert_select "turbo-frame#etoro-setup-accounts input[name='account_ids[]']"

    @item.sync_later

    get setup_accounts_etoro_item_url(@item)

    assert_response :success
    assert_select "turbo-frame#etoro-setup-accounts [data-controller=polling][data-polling-frame-id-value=etoro-setup-accounts][data-polling-url-value=?]", setup_accounts_etoro_item_path(@item)
    assert_select "input[name='account_ids[]']", count: 0

    # What the poll fetches: the frame alone, without the page around it.
    get setup_accounts_etoro_item_url(@item), headers: { "Turbo-Frame" => "etoro-setup-accounts" }

    assert_response :success
    assert_select "turbo-frame#etoro-setup-accounts [data-controller=polling]"
    assert_select "title", count: 0
  end

  test "setup accounts lists the buys and sells only for an account shown as holdings" do
    trades_item = I18n.t("etoro_items.setup_accounts.info_box.items.item_2")

    get setup_accounts_etoro_item_url(@item)
    assert_select "li", text: trades_item

    @etoro_account.update!(display_mode: :totals)
    get setup_accounts_etoro_item_url(@item)
    assert_select "li", text: trades_item, count: 0
  end

  test "setup accounts offers only the manual accounts the user may write to" do
    private_account = member_investment_account
    shared_account = member_investment_account(shared_with_admin: "read_write")

    get setup_accounts_etoro_item_url(@item)

    assert_response :success
    assert_select "select[name=account_id] option[value=?]", accounts(:investment).id
    assert_select "select[name=account_id] option[value=?]", private_account.id, count: 0
    assert_select "select[name=account_id] option[value=?]", shared_account.id, count: 0
  end

  test "select existing account lists the unlinked eToro account" do
    get select_existing_account_etoro_items_url(account_id: accounts(:investment).id)

    assert_response :success
    assert_select "input[type=radio][name=etoro_account_id][value=?]", @etoro_account.id
  end

  test "select existing account rejects an account the user cannot see" do
    get select_existing_account_etoro_items_url(account_id: member_investment_account.id)

    assert_response :not_found
  end

  test "select existing account rejects an account shared without full control" do
    get select_existing_account_etoro_items_url(account_id: member_investment_account(shared_with_admin: "read_write").id)

    assert_redirected_to accounts_path
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
  end

  test "link existing account links a manual investment account and syncs it" do
    account = accounts(:investment)

    assert_no_difference "DebugLogEntry.count" do
      assert_difference "AccountProvider.count", 1 do
        assert_enqueued_with(job: SyncJob) do
          post link_existing_account_etoro_items_url, params: { account_id: account.id, etoro_account_id: @etoro_account.id }
        end
      end
    end

    assert_redirected_to account_path(account)
    assert_equal account, @etoro_account.reload.current_account
  end

  test "link existing account rejects an account that is not a manual investment account" do
    assert_no_difference "AccountProvider.count" do
      post link_existing_account_etoro_items_url, params: { account_id: accounts(:depository).id, etoro_account_id: @etoro_account.id }
    end

    assert_redirected_to account_path(accounts(:depository))
    assert_equal I18n.t("etoro_items.link_existing_account.only_manual_investment"), flash[:alert]
  end

  test "link existing account rejects an eToro account linked elsewhere" do
    other = families(:dylan_family).accounts.create!(name: "Other brokerage", balance: 0, currency: "USD", owner: users(:family_admin), accountable: Investment.new)
    @etoro_account.ensure_account_provider!(other)

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_etoro_items_url, params: { account_id: accounts(:investment).id, etoro_account_id: @etoro_account.id }
    end

    assert_redirected_to account_path(accounts(:investment))
    assert_equal I18n.t("etoro_items.link_existing_account.already_linked"), flash[:alert]
  end

  test "link existing account does not reach another family's eToro account" do
    other_item = families(:empty).etoro_items.create!(name: "Elsewhere", api_key: "key", user_key: "user")
    other_account = other_item.etoro_accounts.create!(name: "eToro", etoro_account_id: "other", currency: "USD")

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_etoro_items_url, params: { account_id: accounts(:investment).id, etoro_account_id: other_account.id }
    end

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("etoro_items.link_existing_account.not_found"), flash[:alert]
  end

  test "link existing account rejects an account the user cannot see" do
    account = member_investment_account

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_etoro_items_url, params: { account_id: account.id, etoro_account_id: @etoro_account.id }
    end

    assert_redirected_to settings_providers_path
    assert_unchanged account
  end

  test "link existing account rejects an account shared without full control" do
    account = member_investment_account(shared_with_admin: "read_write")

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_etoro_items_url, params: { account_id: account.id, etoro_account_id: @etoro_account.id }
    end

    assert_redirected_to accounts_path
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
    assert_unchanged account
  end

  test "link existing account accepts an account shared with full control" do
    account = member_investment_account(shared_with_admin: "full_control")

    assert_difference "AccountProvider.count", 1 do
      post link_existing_account_etoro_items_url, params: { account_id: account.id, etoro_account_id: @etoro_account.id }
    end

    assert_redirected_to account_path(account)
  end

  test "sync starts a sync" do
    assert_enqueued_with(job: SyncJob) do
      post sync_etoro_item_url(@item)
    end

    assert_response :redirect
  end

  test "sync from the panel re-renders the panel in place" do
    post sync_etoro_item_url(@item, source: "panel"), as: :turbo_stream

    assert_turbo_stream action: "replace", target: "etoro-providers-panel"
    assert @item.reload.syncing?
  end

  test "accounts page lets an admin choose how a linked account shows" do
    @etoro_account.ensure_account_provider!(accounts(:investment))

    get accounts_url

    assert_response :success
    assert_select "form[action=?]", update_display_mode_etoro_item_path(@item) do
      assert_select "input[name=etoro_account_id][value=?]", @etoro_account.id
      assert_select "input[name=display_mode][value=holdings]"
      assert_select "[role=option][data-value=totals]", text: I18n.t("etoro_items.display_mode.options.totals")
      assert_select "button[type=submit]", text: I18n.t("etoro_items.display_mode.change")
    end
  end

  test "each account's display mode control is labelled by its own label" do
    @etoro_account.ensure_account_provider!(accounts(:investment))
    second = @item.etoro_accounts.create!(etoro_account_id: "second", name: "Second", currency: "USD")
    second.ensure_account_provider!(Account.create_from_etoro_account(second))

    get accounts_url

    triggers = css_select("form[action='#{update_display_mode_etoro_item_path(@item)}'] button[aria-haspopup=listbox]")
    assert_equal 2, triggers.size
    assert_equal 2, triggers.map { |trigger| trigger["id"] }.uniq.size

    triggers.each do |trigger|
      label_id, trigger_id = trigger["aria-labelledby"].to_s.split
      assert_equal trigger["id"], trigger_id
      assert_select "label##{label_id}", count: 1
    end
  end

  test "accounts page shows the display mode without the choice while a sync runs" do
    @etoro_account.ensure_account_provider!(accounts(:investment))
    @item.syncs.create!

    get accounts_url

    assert_select "form[action=?]", update_display_mode_etoro_item_path(@item), count: 0
    assert_select "p", text: I18n.t("etoro_items.display_mode.wait_for_sync")
  end

  test "the display mode choice asks for confirmation before it rebuilds the account" do
    @etoro_account.ensure_account_provider!(accounts(:investment))

    get accounts_url

    form = css_select("form[action='#{update_display_mode_etoro_item_path(@item)}']").sole
    confirm = JSON.parse(form["data-turbo-confirm"])
    assert_equal I18n.t("etoro_items.display_mode.confirm.title", account: accounts(:investment).name), confirm["title"]
    assert_equal I18n.t("etoro_items.display_mode.confirm.body"), confirm["body"]
    # Only its button submits the form, so picking a mode asks nothing yet,
    # and cancelling leaves the choice unsubmitted.
    assert_not_includes form["data-controller"].to_s.split, "auto-submit-form"
  end

  test "accounts page shows the display mode without the choice to an admin who may not change the account" do
    account = member_investment_account(shared_with_admin: "read_write")
    @etoro_account.ensure_account_provider!(account)

    get accounts_url

    assert_select "form[action=?]", update_display_mode_etoro_item_path(@item), count: 0
    assert_select "p", text: shows_as(account)
  end

  test "accounts page shows the display mode of a disabled account without the choice" do
    @etoro_account.ensure_account_provider!(accounts(:investment))
    accounts(:investment).disable!

    get accounts_url

    assert_select "form[action=?]", update_display_mode_etoro_item_path(@item), count: 0
    assert_select "p", text: shows_as(accounts(:investment))
  end

  test "changing the display mode saves it and syncs the connection" do
    @etoro_account.ensure_account_provider!(accounts(:investment))

    patch update_display_mode_etoro_item_url(@item), params: { etoro_account_id: @etoro_account.id, display_mode: "totals" }

    assert_redirected_to accounts_path
    assert_equal I18n.t("etoro_items.update_display_mode.success"), flash[:notice]
    assert @etoro_account.reload.shown_as_totals?
    assert_enqueued_with(job: SyncJob, args: [ @item.syncs.sole ])
  end

  test "keeping the display mode starts no sync" do
    patch update_display_mode_etoro_item_url(@item), params: { etoro_account_id: @etoro_account.id, display_mode: "holdings" }

    assert_redirected_to accounts_path
    assert_nil flash[:notice]
    assert_empty @item.syncs
  end

  test "an admin with full control of the linked account can change its display mode" do
    @etoro_account.ensure_account_provider!(member_investment_account(shared_with_admin: "full_control"))

    patch update_display_mode_etoro_item_url(@item), params: { etoro_account_id: @etoro_account.id, display_mode: "totals" }

    assert_equal I18n.t("etoro_items.update_display_mode.success"), flash[:notice]
    assert @etoro_account.reload.shown_as_totals?
  end

  test "an admin with a read-write share of the linked account cannot change its display mode" do
    @etoro_account.ensure_account_provider!(member_investment_account(shared_with_admin: "read_write"))

    patch update_display_mode_etoro_item_url(@item), params: { etoro_account_id: @etoro_account.id, display_mode: "totals" }

    assert_redirected_to accounts_path
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
    assert @etoro_account.reload.shown_as_holdings?
    assert_empty @item.syncs
  end

  test "an admin with a read-only share of the linked account cannot change its display mode" do
    @etoro_account.ensure_account_provider!(member_investment_account(shared_with_admin: "read_only"))

    patch update_display_mode_etoro_item_url(@item), params: { etoro_account_id: @etoro_account.id, display_mode: "totals" }

    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
    assert @etoro_account.reload.shown_as_holdings?
    assert_empty @item.syncs
  end

  test "the display mode of a disabled account cannot change" do
    @etoro_account.ensure_account_provider!(accounts(:investment))
    accounts(:investment).disable!

    patch update_display_mode_etoro_item_url(@item), params: { etoro_account_id: @etoro_account.id, display_mode: "totals" }

    assert_redirected_to accounts_path
    assert_equal I18n.t("etoro_items.update_display_mode.inactive"), flash[:alert]
    assert @etoro_account.reload.shown_as_holdings?
    assert_empty @item.syncs
  end

  test "the display mode cannot change while a sync is under way" do
    @item.syncs.create!

    patch update_display_mode_etoro_item_url(@item), params: { etoro_account_id: @etoro_account.id, display_mode: "totals" }

    assert_equal I18n.t("etoro_items.update_display_mode.syncing"), flash[:alert]
    assert @etoro_account.reload.shown_as_holdings?
  end

  test "an unknown display mode is refused" do
    patch update_display_mode_etoro_item_url(@item), params: { etoro_account_id: @etoro_account.id, display_mode: "per_copy" }

    assert_equal I18n.t("etoro_items.update_display_mode.invalid"), flash[:alert]
    assert @etoro_account.reload.shown_as_holdings?
  end

  test "a member who is not an admin cannot change the display mode" do
    sign_in users(:family_member)

    patch update_display_mode_etoro_item_url(@item), params: { etoro_account_id: @etoro_account.id, display_mode: "totals" }

    assert @etoro_account.reload.shown_as_holdings?
  end

  test "accounts page offers per copy portfolio, and no control for a copy account" do
    @etoro_account.update!(display_mode: :copies)
    @etoro_account.ensure_account_provider!(accounts(:investment))
    copy = copy_of(@etoro_account, mirror_id: 7)
    copy.ensure_account_provider!(Account.create_from_etoro_account(copy))

    get accounts_url

    assert_select "form[action=?]", update_display_mode_etoro_item_path(@item), count: 1 do
      assert_select "input[name=etoro_account_id][value=?]", @etoro_account.id
      assert_select "[role=option][data-value=copies]", text: I18n.t("etoro_items.display_mode.options.copies")
    end
  end

  test "a copy account has no display mode of its own" do
    copy = copy_of(@etoro_account, mirror_id: 7)

    patch update_display_mode_etoro_item_url(@item), params: { etoro_account_id: copy.id, display_mode: "totals" }

    assert_response :not_found
    assert copy.reload.shown_as_copies?
  end

  test "an admin who may not change a copy account cannot take the account out of per copy portfolio" do
    @etoro_account.update!(display_mode: :copies)
    @etoro_account.ensure_account_provider!(accounts(:investment))
    copy_of(@etoro_account, mirror_id: 7).ensure_account_provider!(member_investment_account(shared_with_admin: "read_write"))

    get accounts_url

    assert_select "form[action=?]", update_display_mode_etoro_item_path(@item), count: 0
    assert_select "p", text: I18n.t("etoro_items.display_mode.current", account: accounts(:investment).name, mode: I18n.t("etoro_items.display_mode.options.copies"))

    patch update_display_mode_etoro_item_url(@item), params: { etoro_account_id: @etoro_account.id, display_mode: "holdings" }

    assert_redirected_to accounts_path
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
    assert @etoro_account.reload.shown_as_copies?
    assert_empty @item.syncs
  end

  test "an admin who may not change a copy account can switch between the other modes but not back to per copy portfolio" do
    @etoro_account.ensure_account_provider!(accounts(:investment))
    # A copy account set up earlier stays linked once the account is no
    # longer split, for a return to per copy portfolio to rebuild.
    copy_of(@etoro_account, mirror_id: 7).ensure_account_provider!(member_investment_account(shared_with_admin: "read_write"))

    patch update_display_mode_etoro_item_url(@item), params: { etoro_account_id: @etoro_account.id, display_mode: "copies" }

    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
    assert @etoro_account.reload.shown_as_holdings?

    patch update_display_mode_etoro_item_url(@item), params: { etoro_account_id: @etoro_account.id, display_mode: "totals" }

    assert_equal I18n.t("etoro_items.update_display_mode.success"), flash[:notice]
    assert @etoro_account.reload.shown_as_totals?
  end

  test "setup accounts lists a copy with the day its history starts" do
    @etoro_account.update!(display_mode: :copies)
    @etoro_account.portfolio_snapshots.create!(mirror_id: 7, date: Date.new(2026, 10, 22), total: 100, cash: 10, username: "trader")
    copy = copy_of(@etoro_account, mirror_id: 7)

    get setup_accounts_etoro_item_url(@item)

    assert_response :success
    assert_select "input[name='account_ids[]'][value=?]", copy.id
    assert_select "p", text: I18n.t("etoro_items.copy_status.recorded_since", date: I18n.l(Date.new(2026, 10, 22), format: :long))
    assert_select "li", text: I18n.t("etoro_items.setup_accounts.info_box.items.copies")
  end

  test "setup accounts shows a copy that was closed as closed" do
    @etoro_account.update!(display_mode: :copies)
    @etoro_account.portfolio_snapshots.create!(mirror_id: 7, date: Date.new(2026, 10, 22), total: 100, cash: 10, username: "trader")
    @etoro_account.portfolio_snapshots.create!(mirror_id: 7, date: Date.new(2026, 10, 24), total: 0, cash: 0, closed: true, username: "trader")
    copy = copy_of(@etoro_account, mirror_id: 7)
    copy.ensure_account_provider!(Account.create_from_etoro_account(copy))

    get setup_accounts_etoro_item_url(@item)

    assert_response :success
    assert_select "span[title=?]", I18n.t("etoro_items.copy_status.closed", date: I18n.l(Date.new(2026, 10, 24), format: :long))
  end

  test "setup accounts lists the buys and sells for an account shown as holdings beside its copy accounts" do
    trades_item = I18n.t("etoro_items.setup_accounts.info_box.items.item_2")
    # A copy set up stays linked once the account is no longer split.
    copy = copy_of(@etoro_account, mirror_id: 7)
    copy.ensure_account_provider!(Account.create_from_etoro_account(copy))

    get setup_accounts_etoro_item_url(@item)
    assert_select "li", text: trades_item

    @etoro_account.update!(display_mode: :copies)
    get setup_accounts_etoro_item_url(@item)
    assert_select "li", text: trades_item, count: 0
  end

  test "setting up an account leaves the processing to the sync it queues" do
    @etoro_account.update!(display_mode: :copies)
    @etoro_account.ensure_account_provider!(accounts(:investment))
    copy = copy_of(@etoro_account, mirror_id: 7)
    EtoroAccount::Processor.expects(:new).never

    assert_difference -> { @item.syncs.count }, 1 do
      post complete_account_setup_etoro_item_url(@item), params: { account_ids: [ copy.id ] }
    end

    assert copy.reload.current_account
  end

  test "linking an existing account leaves the processing to the sync it queues" do
    EtoroAccount::Processor.expects(:new).never

    assert_difference -> { @item.syncs.count }, 1 do
      post link_existing_account_etoro_items_url, params: { account_id: accounts(:investment).id, etoro_account_id: @etoro_account.id }
    end

    assert_equal accounts(:investment), @etoro_account.reload.current_account
  end

  test "a poll after the first sync failed shows the failure without syncing again, and a visit syncs again" do
    @etoro_account.destroy!
    @item.syncs.create!(status: "failed", failed_at: Time.current, error: "timeout")

    EtoroItem.any_instance.expects(:sync_later).never
    get setup_accounts_etoro_item_url(@item), headers: { "Turbo-Frame" => "etoro-setup-accounts" }

    assert_response :success
    assert_select "turbo-frame#etoro-setup-accounts #etoro-setup-sync-failed", text: /#{Regexp.escape(I18n.t("etoro_items.setup_accounts.status.sync_failed_title"))}/
    assert_select "[data-controller=polling]", count: 0
    assert_select "a[href=?]", setup_accounts_etoro_item_path(@item), text: I18n.t("etoro_items.setup_accounts.buttons.try_again")

    EtoroItem.any_instance.unstub(:sync_later)
    EtoroItem.any_instance.expects(:sync_later).once
    get setup_accounts_etoro_item_url(@item)
  end

  test "setup accounts waits for a sync under way before offering the accounts" do
    @item.syncs.create!

    get setup_accounts_etoro_item_url(@item)

    assert_response :success
    assert_select "input[name='account_ids[]']", count: 0
    assert_select "p", text: I18n.t("etoro_items.setup_accounts.status.fetching_accounts")
  end

  test "setting up an account waits for a sync under way" do
    @item.syncs.create!
    EtoroAccount::Processor.any_instance.expects(:process).never

    assert_no_difference "Account.count" do
      post complete_account_setup_etoro_item_url(@item), params: { account_ids: [ @etoro_account.id ] }
    end

    assert_redirected_to setup_accounts_etoro_item_path(@item)
    assert_equal I18n.t("etoro_items.complete_account_setup.syncing"), flash[:alert]
    assert_nil @etoro_account.reload.current_account
  end

  test "linking an existing account waits for a sync under way" do
    @item.syncs.create!
    EtoroAccount::Processor.any_instance.expects(:process).never

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_etoro_items_url, params: { account_id: accounts(:investment).id, etoro_account_id: @etoro_account.id }
    end

    assert_redirected_to account_path(accounts(:investment))
    assert_equal I18n.t("etoro_items.link_existing_account.syncing"), flash[:alert]
  end

  test "destroy unlinks the account and schedules the connection for deletion" do
    @etoro_account.ensure_account_provider!(accounts(:investment))

    assert_enqueued_with(job: DestroyJob) do
      delete etoro_item_url(@item)
    end

    assert_redirected_to settings_providers_path
    assert @item.reload.scheduled_for_deletion?
    assert_not AccountProvider.exists?(provider_type: "EtoroAccount")
  end

  # A sync past its five visible minutes may be a lost job, which would hold
  # the connection for a day. One still running leaves alone the accounts it
  # reaches after the unlink (EtoroItem#process_accounts).
  test "deleting the connection goes ahead when the sync under way is past its visible minutes" do
    @etoro_account.ensure_account_provider!(accounts(:investment))
    @item.syncs.create!(created_at: 10.minutes.ago).start!

    assert_enqueued_with(job: DestroyJob) do
      delete etoro_item_url(@item)
    end

    assert @item.reload.scheduled_for_deletion?
    assert_not AccountProvider.exists?(provider_type: "EtoroAccount")
  end

  test "deleting the connection waits for a sync under way, which still writes to its accounts" do
    @etoro_account.ensure_account_provider!(accounts(:investment))
    @item.syncs.create!

    assert_no_enqueued_jobs(only: DestroyJob) do
      delete etoro_item_url(@item)
    end

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("etoro_items.destroy.syncing"), flash[:alert]
    assert_not @item.reload.scheduled_for_deletion?
    assert_equal accounts(:investment), @etoro_account.reload.current_account
  end

  test "link existing account rejects an account being deleted" do
    account = accounts(:investment)
    account.update_column(:status, "pending_deletion")

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_etoro_items_url, params: { account_id: account.id, etoro_account_id: @etoro_account.id }
    end

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("etoro_items.link_existing_account.not_found"), flash[:alert]
  end

  # Another provider's link to the account, committed after the first check,
  # is seen under the lock.
  test "link existing account checks the account again once it holds its lock" do
    account = accounts(:investment)
    other = @item.etoro_accounts.create!(etoro_account_id: "other", name: "eToro", currency: "USD")
    Account.any_instance.stubs(:lock!).with { AccountProvider.create!(account: account, provider: other) }.returns(account)

    post link_existing_account_etoro_items_url, params: { account_id: account.id, etoro_account_id: @etoro_account.id }

    assert_redirected_to account_path(account)
    assert_equal I18n.t("etoro_items.link_existing_account.only_manual_investment"), flash[:alert]
    assert_nil @etoro_account.reload.current_account
  end

  test "setting up a copy takes write access to its main account, whose value it takes out" do
    @etoro_account.update!(display_mode: :copies)
    @etoro_account.ensure_account_provider!(member_investment_account(shared_with_admin: "read_only"))
    copy = copy_of(@etoro_account, mirror_id: 7)

    assert_no_difference [ "Account.count", -> { @item.syncs.count } ] do
      post complete_account_setup_etoro_item_url(@item), params: { account_ids: [ copy.id ] }
    end

    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
    assert_nil copy.reload.current_account
  end

  test "linking a copy to an existing account takes write access to its main account" do
    @etoro_account.update!(display_mode: :copies)
    @etoro_account.ensure_account_provider!(member_investment_account(shared_with_admin: "read_only"))
    copy = copy_of(@etoro_account, mirror_id: 7)

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_etoro_items_url, params: { account_id: accounts(:investment).id, etoro_account_id: copy.id }
    end

    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
  end

  test "the accounts set up before a failure keep their link and still get their sync" do
    second = @item.etoro_accounts.create!(etoro_account_id: "second", name: "eToro", currency: "USD")
    created = families(:dylan_family).accounts.create!(name: "eToro", balance: 0, currency: "USD", accountable: Investment.new)
    Account.stubs(:create_from_etoro_account).returns(created).then.raises(StandardError, "boom")

    assert_difference -> { @item.syncs.count }, 1 do
      assert_raises(StandardError) do
        post complete_account_setup_etoro_item_url(@item), params: { account_ids: [ @etoro_account.id, second.id ] }
      end
    end

    assert_equal [ created ], [ @etoro_account, second ].filter_map { |etoro_account| etoro_account.reload.current_account }
  end

  # The job of a sync can be lost: past the few minutes a sync counts as under
  # way, the page no longer waits for it.
  test "a poll after a setup sync that never finished offers a retry" do
    @etoro_account.destroy!
    @item.syncs.create!(status: "syncing", created_at: 10.minutes.ago)

    get setup_accounts_etoro_item_url(@item), headers: { "Turbo-Frame" => "etoro-setup-accounts" }

    assert_response :success
    assert_select "turbo-frame#etoro-setup-accounts #etoro-setup-sync-failed"
    assert_select "[data-controller=polling]", count: 0
    assert_select "a[href=?]", setup_accounts_etoro_item_path(@item), text: I18n.t("etoro_items.setup_accounts.buttons.try_again")
  end

  test "the display mode hints describe each mode, showing the saved one until another is picked" do
    @etoro_account.ensure_account_provider!(accounts(:investment))

    get accounts_url

    assert_select "[data-controller=select-hint][data-action~='dropdown:select->select-hint#update']" do
      EtoroAccount.display_modes.each_key do |mode|
        assert_select "p[data-select-hint-target=hint][data-value=?]", mode, text: I18n.t("etoro_items.display_mode.hint.#{mode}")
      end
      assert_select "p[data-select-hint-target=hint]:not([hidden])", count: 1, text: I18n.t("etoro_items.display_mode.hint.holdings")
    end
  end

  test "deleting the connection from its card warns, once copies are recorded, that their history goes with it" do
    get accounts_url
    assert_equal I18n.t("shared.custom_confirm.resource_deletion_body", resource: @item.institution_display_name.downcase), deletion_confirm["body"]

    # Sure records the positions the user opened on every sync; only a copy's
    # records are a history eToro cannot send again.
    @etoro_account.portfolio_snapshots.create!(mirror_id: EtoroPortfolioSnapshot::OWN_POSITIONS, date: Date.current, total: 100, cash: 10)
    get accounts_url
    assert_equal I18n.t("shared.custom_confirm.resource_deletion_body", resource: @item.institution_display_name.downcase), deletion_confirm["body"]

    @etoro_account.portfolio_snapshots.create!(mirror_id: 7, date: Date.current, total: 100, cash: 10, username: "trader")
    get accounts_url
    assert_equal I18n.t("etoro_items.deletion_confirm.title"), deletion_confirm["title"]
    assert_equal I18n.t("etoro_items.deletion_confirm.body"), deletion_confirm["body"]
    assert_equal "destructive", deletion_confirm["variant"]
  end

  private

    def copy_of(main, mirror_id:)
      main.copy_accounts.create!(
        etoro_item: main.etoro_item, mirror_id: mirror_id, etoro_account_id: "#{main.etoro_account_id}-copy-#{mirror_id}",
        name: "eToro copy: trader", currency: "USD", display_mode: :copies
      )
    end

    # A manual investment account another member owns, optionally shared with
    # the signed-in admin.
    def member_investment_account(shared_with_admin: nil)
      account = families(:dylan_family).accounts.create!(
        name: "Pension",
        balance: 123_456,
        currency: "EUR",
        owner: users(:family_member),
        accountable: Investment.new
      )
      account.share_with!(users(:family_admin), permission: shared_with_admin) if shared_with_admin
      account
    end

    # A position opened and closed late in the UTC day, which is already the
    # next day in the family's zone.
    def assert_unchanged(account)
      account.reload
      assert_empty account.account_providers
      assert_equal BigDecimal("123456"), account.balance
      assert_equal "EUR", account.currency
    end

    # The line the card shows in place of the display mode choice, for an
    # account shown as holdings.
    def shows_as(account)
      I18n.t("etoro_items.display_mode.current", account: account.name, mode: I18n.t("etoro_items.display_mode.options.holdings"))
    end

    # The confirmation the card's Delete asks for.
    def deletion_confirm
      button = css_select("form[action='#{etoro_item_path(@item)}'] button[data-turbo-confirm]").sole
      JSON.parse(button["data-turbo-confirm"])
    end
end
