require "test_helper"
require_relative "../support/provider_ingestion_test_helper"

class AkahuLifecycleTest < ActionDispatch::IntegrationTest
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false
  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    ensure_tailwind_build
    SyncJob.stubs(:perform_later)
    DestroyJob.stubs(:perform_later)
    DebugLogEntry.stubs(:capture)
  end

  test "new account picker posts its signed source UUID selection through real lifecycle admission" do
    with_context do |item, actor|
      sign_in actor
      provider
      get select_accounts_akahu_items_path, params: { akahu_item_id: item.id, accountable_type: "Depository" }
      assert_response :success
      token = form_token
      source = item.akahu_accounts.sole
      assert_select "input[name='account_ids[]'][value='#{source.id}']"
      Provider::Akahu.expects(:new).never
      assert_difference "AccountProvider.count", 1 do
        post link_accounts_akahu_items_path, params: { akahu_item_id: item.id, selection_token: token,
          accountable_type: "Depository", account_ids: [ source.id ], return_to: "/accounts?tab=manual" }
      end
      assert_redirected_to "/accounts?tab=manual"
      account = source.reload.current_account
      assert_equal actor.id, account.owner_id
      assert_equal BigDecimal("125"), account.balance
      assert_equal "NZD", account.currency
    end
  end

  test "existing account picker pins its target and preserves the chosen account UUID" do
    with_context do |item, actor|
      sign_in actor
      provider
      account = financial(item, actor)
      other = financial(item, actor, name: "Other")
      get select_existing_account_akahu_items_path, params: { akahu_item_id: item.id, account_id: account.id }
      assert_response :success
      token = form_token
      source = item.akahu_accounts.sole
      assert_no_difference "AccountProvider.count" do
        post link_existing_account_akahu_items_path, params: { akahu_item_id: item.id, selection_token: token,
          account_id: other.id, akahu_account_id: source.id }
      end
      assert_redirected_to settings_providers_path
      post link_existing_account_akahu_items_path, params: { akahu_item_id: item.id, selection_token: token,
        account_id: account.id, akahu_account_id: source.id }
      assert_redirected_to accounts_path
      assert_equal account.id, source.reload.current_account.id
      assert_empty other.account_providers
    end
  end

  test "setup form carries an unscoped token and preserves liability signs and suggested subtypes" do
    with_context do |item, actor|
      sign_in actor
      provider(rows: [ row.merge(_id: "credit-1", type: "CREDITCARD", balance: { current: -40, currency: "NZD" }),
        row.merge(_id: "investment-1", type: "KIWISAVER") ])
      get setup_accounts_akahu_item_path(item)
      assert_response :success
      token = form_token
      assert_select "input[name='account_types[selection_token]']", count: 0
      credit = item.akahu_accounts.find_by!(account_id: "credit-1")
      investment = item.akahu_accounts.find_by!(account_id: "investment-1")
      post complete_account_setup_akahu_item_path(item), params: { selection_token: token,
        account_types: { credit.id => "CreditCard", investment.id => "Investment" } }
      assert_redirected_to accounts_path
      assert_equal BigDecimal("40"), credit.reload.current_account.balance
      assert_equal "credit_card", credit.current_account.accountable.subtype
      assert_equal "retirement", investment.reload.current_account.accountable.subtype
      assert_equal BigDecimal("0"), investment.current_account.cash_balance
    end
  end

  test "missing tampered and wrong flow tokens refuse before HTTP or financial creation" do
    with_context do |item, actor|
      sign_in actor
      source = item.akahu_accounts.create!(name: "Checking", account_id: "checking-1", currency: "NZD")
      wrong_flow = AkahuItem::Selection.issue(item, actor: actor, flow: :complete_account_setup)
      Provider::Akahu.expects(:new).never
      [ nil, "tampered-selection", wrong_flow ].each do |token|
        assert_no_difference [ "Account.count", "AccountProvider.count", "Sync.count" ] do
          post link_accounts_akahu_items_path, params: { akahu_item_id: item.id, selection_token: token,
            account_ids: [ source.id ], accountable_type: "Depository" }
        end
        assert_response :see_other
        assert_redirected_to settings_providers_path
        assert_equal I18n.t("akahu_items.lifecycle.unavailable"), flash[:alert]
      end
    end
  end

  test "another family cannot select or mutate the requested connection" do
    with_context do |item, actor|
      sign_in users(:family_admin)
      Provider::Akahu.expects(:new).never
      assert_no_difference [ "AccountProvider.count", "Sync.count" ] do
        get select_accounts_akahu_items_path, params: { akahu_item_id: item.id }
        assert_response :not_found
        patch akahu_item_path(item), params: { akahu_item: { name: "Changed" } }
        assert_response :not_found
      end
      assert_equal "Akahu", item.reload.name
      assert_equal actor.family_id, item.family_id
    end
  end

  test "nonadmin requests are denied before discovery settings and scheduling" do
    with_context do |item, actor|
      actor.update!(role: "member")
      sign_in actor
      Provider::Akahu.expects(:new).never
      get preload_accounts_akahu_items_path, params: { akahu_item_id: item.id }, as: :json
      assert_response :forbidden
      patch akahu_item_path(item), params: { akahu_item: { name: "Changed" } }, as: :json
      assert_response :forbidden
      post sync_akahu_item_path(item), as: :json
      assert_response :forbidden
      assert_equal "Akahu", item.reload.name
      assert_empty item.syncs
      assert_empty item.akahu_accounts
    end
  end

  test "family admin cannot use an account owned by another user without full control" do
    with_context do |item, actor|
      owner = item.family.users.create!(email: "akahu-owner-#{SecureRandom.uuid}@example.com", password: "akahu-test-password", role: "member")
      account = financial(item, owner)
      sign_in actor
      Provider::Akahu.expects(:new).never
      get select_existing_account_akahu_items_path, params: { akahu_item_id: item.id, account_id: account.id }
      assert_redirected_to settings_providers_path
      assert_empty account.account_providers
      assert_empty item.akahu_accounts
    end
  end

  test "blank credential settings preserve both tokens and a later credential change invalidates the rendered picker" do
    with_context do |item, actor|
      sign_in actor
      provider
      get select_accounts_akahu_items_path, params: { akahu_item_id: item.id }
      token = form_token
      source = item.akahu_accounts.sole
      patch akahu_item_path(item), params: { akahu_item: { name: "Renamed", app_token: "", user_token: "  " } }
      assert_redirected_to settings_providers_path
      assert_equal "original-app-token", item.reload.app_token
      assert_equal "original-user-token", item.user_token
      patch akahu_item_path(item), params: { akahu_item: { user_token: "replacement-token" } }
      assert_redirected_to settings_providers_path
      Provider::Akahu.expects(:new).never
      assert_no_difference "AccountProvider.count" do
        post link_accounts_akahu_items_path, params: { akahu_item_id: item.id, selection_token: token,
          account_ids: [ source.id ], accountable_type: "Depository" }
      end
      assert_redirected_to settings_providers_path
      assert_nil source.reload.current_account
    end
  end

  test "a changed source cache invalidates a rendered selection without recapturing on POST" do
    with_context do |item, actor|
      sign_in actor
      provider
      get select_accounts_akahu_items_path, params: { akahu_item_id: item.id }
      token = form_token
      source = item.akahu_accounts.sole
      source.update!(raw_transactions_payload: [])
      Provider::Akahu.expects(:new).never
      assert_no_difference "Account.count" do
        post link_accounts_akahu_items_path, params: { akahu_item_id: item.id, selection_token: token,
          account_ids: [ source.id ], accountable_type: "Depository" }
      end
      assert_redirected_to settings_providers_path
      assert_nil source.reload.current_account
    end
  end

  test "native and quiescing legacy routes refuse discovery settings and deletion without implying shared setup" do
    %w[quiescing active retired].each do |state|
      with_context do |item, actor|
        sign_in actor
        ProviderMigrationControl.create!(family: item.family, provider_key: "akahu", legacy_type: "AkahuItem",
          legacy_id: item.id, state: state, writer_epoch: state == "quiescing" ? 0 : 1)
        Provider::Akahu.expects(:new).never
        get setup_accounts_akahu_item_path(item)
        assert_redirected_to settings_providers_path
        get edit_akahu_item_path(item)
        assert_redirected_to settings_providers_path
        patch akahu_item_path(item), params: { akahu_item: { app_token: "changed-token" } }
        assert_redirected_to settings_providers_path
        delete akahu_item_path(item)
        assert_redirected_to settings_providers_path
        assert_equal "original-app-token", item.reload.app_token
        refute item.scheduled_for_deletion?
        assert_empty item.akahu_accounts
      end
    end
  end

  test "preload preserves has accounts when all discovered sources are already linked" do
    with_context do |item, actor|
      sign_in actor
      provider
      source = item.akahu_accounts.create!(name: "Checking", account_id: "checking-1", currency: "NZD")
      AccountProvider.create!(account: financial(item, actor), provider: source)
      get preload_accounts_akahu_items_path, params: { akahu_item_id: item.id }, as: :json
      assert_response :success
      assert_equal true, response.parsed_body.fetch("success")
      assert_equal true, response.parsed_body.fetch("has_accounts")
    end
  end

  test "JSON discovery denial is a sanitized conflict and never a successful empty inventory" do
    with_context do |item, actor|
      sign_in actor
      ProviderMigrationControl.create!(family: item.family, provider_key: "akahu", legacy_type: "AkahuItem", legacy_id: item.id, state: "quiescing")
      Provider::Akahu.expects(:new).never
      get preload_accounts_akahu_items_path, params: { akahu_item_id: item.id }, as: :json
      assert_response :conflict
      assert_equal false, response.parsed_body.fetch("success")
      assert_equal "ownership_changed", response.parsed_body.fetch("error")
      assert_nil response.parsed_body.fetch("has_accounts")
      refute_includes response.body, "original-user-token"
    end
  end

  test "unexpected discovery errors expose only localized copy and safe diagnostic metadata" do
    with_context do |item, actor|
      sign_in actor
      raw_message = "original-user-token raw provider response"
      provider { raise IOError, raw_message }
      DebugLogEntry.expects(:capture).with do |attributes|
        attributes[:source] == "AkahuItemsController" && attributes[:provider_key] == "akahu" && attributes[:family].id == item.family_id &&
          attributes[:metadata] == { action: "preload_accounts", akahu_item_id: item.id, error_class: "IOError" } &&
          !attributes.to_s.include?(raw_message)
      end.once
      get preload_accounts_akahu_items_path, params: { akahu_item_id: item.id }, as: :json
      assert_response :service_unavailable
      assert_equal false, response.parsed_body.fetch("success")
      assert_nil response.parsed_body.fetch("has_accounts")
      refute_includes response.body, raw_message
      assert_empty item.akahu_accounts
    end
  end

  test "Turbo settings denial renders a localized panel error without raw exception data" do
    with_context do |item, actor|
      sign_in actor
      raw_message = "original-user-token raw database failure"
      AkahuItem::Lifecycle.any_instance.stubs(:update_settings).raises(Fence::Busy.new(raw_message))
      patch akahu_item_path(item), params: { akahu_item: { name: "Changed" } },
        headers: { "Turbo-Frame" => "akahu-providers-panel", "Accept" => "text/vnd.turbo-stream.html" }
      assert_response :conflict
      assert_select "turbo-stream[target='akahu-providers-panel']"
      assert_includes response.body, I18n.t("akahu_items.lifecycle.unavailable")
      refute_includes response.body, raw_message
      assert_equal "Akahu", item.reload.name
    end
  end

  test "native manual sync targets the exact mapped shared connection" do
    with_context do |item, actor|
      sign_in actor
      connection = create_provider_connection(family: item.family, provider_key: "akahu", writer_epoch: 1,
        credentials: { "app_token" => "native-app-token", "user_token" => "native-user-token" })
      control = ProviderMigrationControl.create!(family: item.family, provider_key: "akahu", legacy_type: "AkahuItem",
        legacy_id: item.id, state: "active", writer_epoch: 1, provider_connection: connection)
      ProviderMigrationMapping.create!(family: item.family, provider_migration_control: control, role: "connection",
        legacy_type: "AkahuItem", legacy_id: item.id, provider_connection: connection)
      Provider::Akahu.expects(:new).never
      assert_difference -> { connection.syncs.count }, 1 do
        assert_no_difference -> { item.syncs.count } do
          post sync_akahu_item_path(item), as: :json
        end
      end
      assert_response :success
      refute item.reload.scheduled_for_deletion?
    end
  end

  test "legacy manual sync and disconnect use commands and preserve financial accounts" do
    with_context do |item, actor|
      sign_in actor
      source = item.akahu_accounts.create!(name: "Checking", account_id: "checking-1", currency: "NZD")
      account = financial(item, actor)
      AccountProvider.create!(account: account, provider: source)
      entry = account.entries.create!(name: "Recorded purchase", date: Date.current, amount: 7,
        currency: "NZD", entryable: Transaction.new)
      Provider::Akahu.expects(:new).never
      post sync_akahu_item_path(item), as: :json
      assert_response :success
      assert_equal 1, item.syncs.count
      delete akahu_item_path(item)
      assert_redirected_to settings_providers_path
      assert item.reload.scheduled_for_deletion?
      assert_nil source.reload.current_account
      assert Account.exists?(account.id)
      assert Entry.exists?(entry.id)
    end
  end

  test "create schedules the new connection and never changes another connection" do
    with_context do |item, actor|
      sign_in actor
      Provider::Akahu.expects(:new).never
      assert_difference "AkahuItem.count", 1 do
        post akahu_items_path, params: { akahu_item: { name: "Second connection", app_token: "new-app-token", user_token: "new-user-token" } }
      end
      assert_redirected_to settings_providers_path
      created = item.family.akahu_items.find_by!(name: "Second connection")
      assert_equal "new-user-token", created.user_token
      assert_equal 1, created.syncs.count
      assert_equal "original-user-token", item.reload.user_token
    end
  end

  private
    def form_token
      field = response.parsed_body.at_css('input[name="selection_token"]')
      assert field, "expected a signed selection field"
      assert field["value"].present?
      field["value"]
    end

    def row
      { _id: "checking-1", name: "Checking", type: "CHECKING", status: "ACTIVE",
        balance: { current: 125, currency: "NZD" } }
    end

    def provider(rows: [ row ], &read)
      test = self
      client = Object.new
      client.define_singleton_method(:get_accounts) do
        test.assert_equal 0, ApplicationRecord.connection.open_transactions
        read&.call
        rows
      end
      Provider::Akahu.stubs(:new).returns(client)
      client
    end

    def financial(item, actor, name: "Manual")
      item.family.accounts.create!(owner: actor, name: name, currency: "NZD", balance: 9, accountable: Depository.new)
    end

    def with_context
      with_provider_encryption do
        family = Family.create!(name: "Akahu browser lifecycle")
        actor = family.users.create!(email: "akahu-lifecycle-#{SecureRandom.uuid}@example.com", password: user_password_test,
          role: "admin", onboarded_at: 3.days.ago)
        item = family.akahu_items.create!(name: "Akahu", app_token: "original-app-token", user_token: "original-user-token")
        yield item, actor
      ensure
        if family&.persisted?
          Account::SourcePolicy.where(family_id: family.id).delete_all
          AccountProvider.where(account_id: family.accounts.select(:id)).delete_all
          family.accounts.reload.each(&:destroy!)
          ProviderMigrationMapping.where(family_id: family.id).delete_all
          ProviderMigrationControl.where(family_id: family.id).delete_all
          family.provider_connections.each(&:destroy!)
          item_ids = family.akahu_items.pluck(:id)
          Sync.where(syncable_type: "AkahuItem", syncable_id: item_ids).delete_all
          AkahuAccount.where(akahu_item_id: item_ids).delete_all
          AkahuItem.where(id: item_ids).delete_all
          Session.where(user_id: family.users.select(:id)).delete_all
          family.users.delete_all
          family.destroy!
        end
      end
    end
end
