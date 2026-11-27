require "test_helper"

class StashawayItemsControllerTest < ActionDispatch::IntegrationTest
  include StashawayTestHelper

  PANEL = { "Turbo-Frame" => "stashaway-connect-form" }.freeze

  setup do
    sign_in users(:family_admin)
    @item = stashaway_items(:connected)
    @stashaway_account = stashaway_accounts(:general)
  end

  test "connects when StashAway serves data for the password step's token" do
    stub_login(usable: true)

    assert_difference "StashawayItem.count", 1 do
      post stashaway_items_url, params: { stashaway_login: { email: "new@example.com", password: "secret" } }, headers: PANEL
    end

    assert_response :success
    item = StashawayItem.order(:created_at).last
    assert item.ready_for_sync?
    assert_enqueued_with(job: SyncJob, args: [ item.syncs.sole ])
  end

  test "a new connection signs in on the chosen region" do
    stub_login(usable: true)

    post stashaway_items_url, params: { stashaway_login: { region: "th", email: "new@example.com", password: "secret" } }, headers: PANEL

    assert_response :success
    item = StashawayItem.order(:created_at).last
    assert_equal [ "th", "StashAway Thailand" ], [ item.region, item.name ]
  end

  test "an unknown region is refused before reaching StashAway" do
    Provider::Stashaway.any_instance.expects(:login).never

    assert_no_difference "StashawayItem.count" do
      post stashaway_items_url, params: { stashaway_login: { region: "us", email: "new@example.com", password: "secret" } }, headers: PANEL
    end

    assert_response :unprocessable_entity
  end

  test "asks for the SMS code when StashAway wants one" do
    stub_login(usable: false)
    Provider::Stashaway.any_instance.expects(:send_two_factor_code).with(token: "login-token").returns(true)

    post stashaway_items_url, params: { stashaway_login: { email: "new@example.com", password: "secret" } }, headers: PANEL

    assert_response :success
    item = StashawayItem.order(:created_at).last
    assert item.login_pending?
    assert_no_enqueued_jobs only: SyncJob
    assert_select "turbo-stream[target=stashaway-providers-panel] template form[action=?]", verify_code_stashaway_item_path(item)
  end

  test "a refused password saves nothing and keeps the email in the form" do
    Provider::Stashaway.any_instance.stubs(:login).raises(Provider::Stashaway::InvalidCredentials, "Incorrect email or password")

    assert_no_difference "StashawayItem.count" do
      post stashaway_items_url, params: { stashaway_login: { email: "new@example.com", password: "wrong" } }, headers: PANEL
    end

    assert_response :unprocessable_entity
    assert_select "turbo-stream[target=stashaway-providers-panel] template input[name='stashaway_login[email]'][value=?]", "new@example.com"
    assert_select "turbo-stream template p", text: /Incorrect email or password/
  end

  test "a failed sign-in is explained in the user's language, the client's message only logged" do
    users(:family_admin).update!(locale: "fr")
    I18n.backend.send(:init_translations) unless I18n.backend.initialized?
    I18n.backend.store_translations(:fr, stashaway_items: { login_errors: { rate_limited: "StashAway limite les requêtes." } })
    Provider::Stashaway.any_instance.stubs(:login).raises(Provider::Stashaway::RateLimited, "StashAway is limiting requests; try again in a few minutes")

    post stashaway_items_url, params: { stashaway_login: { email: "new@example.com", password: "secret" } }, headers: PANEL

    assert_select "turbo-stream template p", text: /StashAway limite les requêtes\./
    assert_select "turbo-stream template p", text: /is limiting requests/, count: 0
    assert DebugLogEntry.where("message LIKE ?", "%RateLimited - StashAway is limiting requests%").exists?
  ensure
    I18n.reload!
  end

  test "each kind of sign-in failure has its own message" do
    {
      Provider::Stashaway::UnsupportedVerification => "unsupported_verification",
      Provider::Stashaway::UnsupportedClient => "unsupported_client",
      Provider::Stashaway::TransientError => "unavailable",
      Provider::Stashaway::ApiError.new("StashAway did not return a session", status_code: 200) => "failed"
    }.each do |error, key|
      Provider::Stashaway.any_instance.stubs(:login).raises(error)

      post stashaway_items_url, params: { stashaway_login: { email: "new@example.com", password: "secret" } }, headers: PANEL

      assert_select "turbo-stream template p", { text: /#{Regexp.escape(I18n.t("stashaway_items.login_errors.#{key}"))}/ }, error.inspect
    end
  end

  test "a sign-in without a password does not reach StashAway" do
    Provider::Stashaway.any_instance.expects(:login).never

    post stashaway_items_url, params: { stashaway_login: { email: "new@example.com", password: "" } }, headers: PANEL

    assert_response :unprocessable_entity
  end

  test "the SMS code completes the sign-in and starts a sync" do
    @item.update!(status: :requires_update, api_token: nil, pending_login_token: "login-token", pending_login_started_at: Time.current)
    Provider::Stashaway.any_instance.expects(:verify_two_factor)
      .with(code: "123456", token: "login-token", device_id: @item.device_id).returns("new-api-token")

    post verify_code_stashaway_item_url(@item), params: { stashaway_login: { code: "123456" } }, headers: PANEL

    assert_response :success
    assert @item.reload.ready_for_sync?
    assert_equal "new-api-token", @item.api_token
    assert_enqueued_with(job: SyncJob)
  end

  test "a refused code keeps the code form" do
    @item.update!(status: :requires_update, api_token: nil, pending_login_token: "login-token", pending_login_started_at: Time.current)
    Provider::Stashaway.any_instance.stubs(:verify_two_factor).raises(Provider::Stashaway::InvalidCode, "Invalid OTP")

    post verify_code_stashaway_item_url(@item), params: { stashaway_login: { code: "000000" } }, headers: PANEL

    assert_response :unprocessable_entity
    assert @item.reload.login_pending?
    assert_select "turbo-stream template form[action=?]", verify_code_stashaway_item_path(@item)
  end

  test "an expired connection signs in again with its own email" do
    @item.require_reauthentication!
    Provider::Stashaway.any_instance.expects(:login)
      .with(email: "investor@example.com", password: "secret", device_id: @item.device_id)
      .returns(Provider::Stashaway::Session.new(token: "login-token", user_id: "sa-user-1"))
    Provider::Stashaway.any_instance.stubs(:usable_token?).returns(false)
    Provider::Stashaway.any_instance.stubs(:send_two_factor_code).returns(true)

    post login_stashaway_item_url(@item), params: { stashaway_login: { password: "secret" } }, headers: PANEL

    assert_response :success
    assert @item.reload.login_pending?
  end

  test "cancelling the code step drops the pending sign-in" do
    @item.update!(pending_login_token: "login-token", pending_login_started_at: Time.current)

    post cancel_login_stashaway_item_url(@item), headers: PANEL

    assert_nil @item.reload.pending_login_token
  end

  test "the providers panel shows the sign-in form for a connection that needs one" do
    @item.require_reauthentication!

    get connect_form_settings_providers_path(provider_key: "stashaway")

    assert_response :success
    assert_select "#stashaway-providers-panel details summary span.overflow-hidden.shrink-0", minimum: 1, message: "the connection row shows the provider logo"
    assert_select "turbo-frame#stashaway-connect-form form[action=?] input[type=password]", login_stashaway_item_path(@item)
    assert_select "turbo-frame#stashaway-connect-form form[action=?]", stashaway_items_path
    assert_select "turbo-frame#stashaway-connect-form input[type=password]", 2 do |inputs|
      assert_equal 2, inputs.map { |input| input["id"] }.uniq.size
    end
  end

  test "complete account setup creates a linked account of the portfolio's type" do
    StashawayAccount::Processor.any_instance.expects(:process)

    assert_difference "Account.count", 1 do
      post complete_account_setup_stashaway_item_url(@item), params: { account_ids: [ @stashaway_account.id ] }
    end

    assert_redirected_to accounts_path
    account = @stashaway_account.reload.current_account
    assert_equal [ "Investment", "SGD", "StashAway SG: General Investing" ], [ account.accountable_type, account.currency, account.name ]
    assert_nil @stashaway_account.import_start_date
  end

  test "new accounts are named after the connection's region" do
    StashawayAccount::Processor.any_instance.stubs(:process)
    @item.update!(region: "ae")

    post complete_account_setup_stashaway_item_url(@item), params: { account_ids: [ @stashaway_account.id ] }

    assert_equal "StashAway MENA: General Investing", @stashaway_account.reload.current_account.name
  end

  test "the connect form offers every region, Singapore first" do
    get connect_form_settings_providers_path(provider_key: "stashaway")

    assert_select "turbo-frame#stashaway-connect-form select[name='stashaway_login[region]'] option" do |options|
      assert_equal %w[sg my hk ae th], options.map { |option| option["value"] }
      assert_equal "sg", options.find { |option| option["selected"] }&.[]("value")
    end
  end

  test "linking an existing manual account imports after its own entries" do
    account = families(:dylan_family).accounts.create!(name: "StashAway (statements)", balance: 1000, currency: "SGD", accountable: Investment.new)
    account.entries.create!(date: Date.new(2026, 1, 31), name: "Statement", amount: -1000, currency: "SGD", entryable: Transaction.new)
    StashawayAccount::Processor.any_instance.expects(:process)

    post link_existing_account_stashaway_items_url, params: { account_id: account.id, stashaway_account_id: @stashaway_account.id }

    assert_redirected_to account_path(account)
    assert_equal account, @stashaway_account.reload.current_account
    assert_equal Date.new(2026, 2, 1), @stashaway_account.import_start_date
  end

  test "a link whose first processing fails still queues a sync to retry it" do
    account = families(:dylan_family).accounts.create!(name: "StashAway (statements)", balance: 1000, currency: "SGD", accountable: Investment.new)
    StashawayAccount::Processor.any_instance.stubs(:process).raises(Provider::Stashaway::Error, "Failed to set the current balance")

    post link_existing_account_stashaway_items_url, params: { account_id: account.id, stashaway_account_id: @stashaway_account.id }

    assert_redirected_to account_path(account)
    assert_equal account, @stashaway_account.reload.current_account
    assert_enqueued_with(job: SyncJob, args: [ @item.syncs.order(:created_at).last ])
    assert DebugLogEntry.where("message LIKE ?", "Failed to process StashAway account #{@stashaway_account.id} after linking%").exists?
  end

  test "an account linked to another provider cannot be linked" do
    StashawayAccount::Processor.any_instance.expects(:process).never

    post link_existing_account_stashaway_items_url, params: { account_id: accounts(:connected).id, stashaway_account_id: @stashaway_account.id }

    assert_redirected_to account_path(accounts(:connected))
    assert_nil @stashaway_account.reload.current_account
  end

  test "setup accounts lists the discovered portfolio and the manual accounts to link" do
    get setup_accounts_stashaway_item_url(@item)

    assert_response :success
    assert_select "input[name='account_ids[]'][value=?]", @stashaway_account.id
    assert_select "select[name=account_id] option[value=?]", accounts(:investment).id
  end

  test "accounts page shows the connection card, with the sync frequency entry in its menu" do
    get accounts_url

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(@item)}"
    assert_select "a[href=?]", edit_sync_schedule_path(syncable_type: "StashawayItem", syncable_id: @item.id), text: I18n.t("sync_schedules.menu_item")
  end

  test "disconnect schedules the deletion" do
    delete stashaway_item_url(@item)

    assert_redirected_to settings_providers_path
    assert @item.reload.scheduled_for_deletion?
  end

  test "a link from another provider that commits before the lock is refused" do
    account = families(:dylan_family).accounts.create!(name: "StashAway (manual)", balance: 1000, currency: "SGD", accountable: Investment.new)
    competitor = trading212_accounts(:main_account)
    # The manual check has passed when the other link commits. The controller
    # loads its own Account, so the hook lives on the class and is restored.
    original_with_lock = Account.instance_method(:with_lock)
    Account.define_method(:with_lock) do |*args, &block|
      AccountProvider.create!(account: self, provider: competitor) if id == account.id
      original_with_lock.bind(self).call(*args, &block)
    end
    StashawayAccount::Processor.any_instance.expects(:process).never

    post link_existing_account_stashaway_items_url, params: { account_id: account.id, stashaway_account_id: @stashaway_account.id }

    assert_redirected_to account_path(account)
    assert_equal I18n.t("stashaway_items.link_existing_account.only_manual"), flash[:alert]
    assert_nil @stashaway_account.reload.current_account
  ensure
    Account.define_method(:with_lock, original_with_lock) if original_with_lock
  end

  test "an admin is offered the sign-in from the card" do
    @item.require_reauthentication!

    get accounts_url

    assert_select "##{ActionView::RecordIdentifier.dom_id(@item)} a[href=?]", settings_providers_path, text: "Sign in"
  end

  test "a member sees the sign-in warning without the admin-only link" do
    AccountProvider.create!(account: accounts(:depository), provider: @stashaway_account)
    @item.require_reauthentication!
    sign_in users(:family_member)

    get accounts_url

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(@item)}" do
      assert_select "span", text: "Sign-in needed"
      assert_select "a[href=?]", settings_providers_path, count: 0
    end
  end

  test "a connection scheduled for deletion offers no account setup" do
    @item.update!(scheduled_for_deletion: true)

    get accounts_url
    assert_select "##{ActionView::RecordIdentifier.dom_id(@item)} a[href=?]", setup_accounts_stashaway_item_path(@item), count: 0

    get setup_accounts_stashaway_item_url(@item)
    assert_redirected_to accounts_path
    assert_equal I18n.t("stashaway_items.scheduled_for_deletion"), flash[:alert]
  end

  test "a connection scheduled for deletion creates no accounts" do
    @item.update!(scheduled_for_deletion: true)
    StashawayAccount::Processor.any_instance.expects(:process).never

    assert_no_difference "Account.count" do
      post complete_account_setup_stashaway_item_url(@item), params: { account_ids: [ @stashaway_account.id ] }
    end

    assert_redirected_to accounts_path
    assert_nil @stashaway_account.reload.current_account
  end

  test "a connection scheduled for deletion is not offered for linking" do
    @item.update!(scheduled_for_deletion: true)

    get select_accounts_stashaway_items_url
    assert_redirected_to settings_providers_path

    post link_existing_account_stashaway_items_url, params: { account_id: accounts(:investment).id, stashaway_account_id: @stashaway_account.id }
    assert_redirected_to settings_providers_path
    assert_equal I18n.t("stashaway_items.link_existing_account.not_found"), flash[:alert]
    assert_nil @stashaway_account.reload.current_account
  end

  test "the link dialog requires a portfolio to be chosen" do
    get select_existing_account_stashaway_items_url(account_id: accounts(:investment).id)

    assert_response :success
    assert_select "input[type=radio][name=stashaway_account_id][required]", 1
  end

  test "setup accounts explains a connection that is still signing in" do
    @stashaway_account.destroy!
    @item.update!(status: :requires_update, api_token: nil, pending_login_token: "login-token", pending_login_started_at: Time.current)

    get setup_accounts_stashaway_item_url(@item)

    assert_response :success
    assert_select "form[action=?]", complete_account_setup_stashaway_item_path(@item), count: 0
    assert_select "a[href=?]", settings_providers_path, text: /Back to Settings/
    assert_no_enqueued_jobs only: SyncJob
  end

  test "setup accounts reports a sync that found no portfolios" do
    @stashaway_account.destroy!
    @item.syncs.create!(status: "completed", completed_at: Time.current)

    get setup_accounts_stashaway_item_url(@item)

    assert_response :success
    assert_select "p", text: "No portfolios found."
    assert_select "a[href=?]", settings_providers_path, text: /Back to Settings/
  end

  private

    def stub_login(usable:)
      Provider::Stashaway.any_instance.stubs(:login).returns(Provider::Stashaway::Session.new(token: "login-token", user_id: "sa-user-9"))
      Provider::Stashaway.any_instance.stubs(:usable_token?).with("login-token").returns(usable)
    end
end
