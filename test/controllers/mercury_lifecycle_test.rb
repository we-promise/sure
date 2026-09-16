require "test_helper"
require_relative "../support/mercury_lifecycle_test_helper"

class MercuryLifecycleTest < ActionDispatch::IntegrationTest
  include MercuryLifecycleTestHelper
  self.use_transactional_tests = false

  setup do
    SyncJob.stubs(:perform_later)
    DestroyJob.stubs(:perform_later)
    DebugLogEntry.stubs(:capture)
  end

  test "new account GET form submits its actual signed selection through the legacy command" do
    with_mercury_context do |item, actor|
      sign_in actor
      mercury_provider
      get select_accounts_mercury_items_path, params: { mercury_item_id: item.id, accountable_type: "Depository" }
      assert_response :success
      token = response.parsed_body.at_css('input[name="selection_token"]')["value"]
      assert token.present?
      assert_difference "AccountProvider.count", 1 do
        post link_accounts_mercury_items_path, params: { mercury_item_id: item.id, selection_token: token,
          accountable_type: "Depository", account_ids: [ "checking-1" ] }
      end
      assert_redirected_to accounts_path
      assert_equal actor.id, item.mercury_accounts.sole.current_account.owner_id
    end
  end

  test "existing account GET form pins the financial target on POST" do
    with_mercury_context do |item, actor|
      sign_in actor
      mercury_provider
      account = mercury_financial(item, actor)
      other = mercury_financial(item, actor, name: "Other")
      get select_existing_account_mercury_items_path, params: { mercury_item_id: item.id, account_id: account.id }
      assert_response :success
      token = response.parsed_body.at_css('input[name="selection_token"]')["value"]
      assert_no_difference "AccountProvider.count" do
        post link_existing_account_mercury_items_path, params: { mercury_item_id: item.id, selection_token: token,
          account_id: other.id, mercury_account_id: "checking-1" }
      end
      assert_redirected_to settings_providers_path
      post link_existing_account_mercury_items_path, params: { mercury_item_id: item.id, selection_token: token,
        account_id: account.id, mercury_account_id: "checking-1" }
      assert_redirected_to accounts_path
      assert_equal account.id, item.mercury_accounts.sole.current_account.id
      assert_empty other.account_providers
    end
  end

  test "setup GET form carries a usable token for account type completion" do
    with_mercury_context do |item, actor|
      sign_in actor
      mercury_provider
      get setup_accounts_mercury_item_path(item)
      assert_response :success
      token = response.parsed_body.at_css('input[name="selection_token"]')["value"]
      source = item.mercury_accounts.sole
      post complete_account_setup_mercury_item_path(item), params: { selection_token: token,
        account_types: { source.id => "Depository" }, account_subtypes: { source.id => "checking" } }
      assert_redirected_to accounts_path
      assert_equal BigDecimal("125"), source.reload.current_account.balance
    end
  end

  test "a lone configured connection is never substituted for a missing link POST selection" do
    with_mercury_context do |item, actor|
      sign_in actor
      Provider::Mercury.expects(:new).never
      assert_no_difference [ "Account.count", "AccountProvider.count", "MercuryAccount.count" ] do
        post link_accounts_mercury_items_path, params: { account_ids: [ "checking-1" ], accountable_type: "Depository" }
        assert_redirected_to settings_providers_path
        post link_accounts_mercury_items_path, params: { mercury_item_id: item.id, account_ids: [ "checking-1" ], accountable_type: "Depository" }
        assert_redirected_to settings_providers_path
      end
    end
  end

  test "credential update invalidates a rendered form before any second HTTP request" do
    with_mercury_context do |item, actor|
      sign_in actor
      mercury_provider
      get select_accounts_mercury_items_path, params: { mercury_item_id: item.id }
      token = response.parsed_body.at_css('input[name="selection_token"]')["value"]
      patch mercury_item_path(item), params: { mercury_item: { token: "replacement-token" } }
      assert_redirected_to accounts_path
      Provider::Mercury.expects(:new).never
      post link_accounts_mercury_items_path, params: { mercury_item_id: item.id, selection_token: token, account_ids: [ "checking-1" ], accountable_type: "Depository" }
      assert_redirected_to settings_providers_path
      assert_empty item.mercury_accounts
    end
  end

  test "quiesced cached discovery settings and deletion refuse before legacy effects" do
    with_mercury_context do |item, actor|
      sign_in actor
      Rails.cache.write(MercuryItem::Selection.cache_key(item), mercury_rows)
      ProviderMigrationControl.create!(family: item.family, provider_key: "mercury", legacy_type: "MercuryItem", legacy_id: item.id, state: "quiescing")
      Provider::Mercury.expects(:new).never
      DestroyJob.expects(:perform_later).never
      get preload_accounts_mercury_items_path, params: { mercury_item_id: item.id }, as: :json
      assert_response :conflict
      patch mercury_item_path(item), params: { mercury_item: { token: "forbidden" } }
      assert_redirected_to settings_providers_path
      delete mercury_item_path(item)
      assert_redirected_to settings_providers_path
      assert_equal "original-token", item.reload.token
      assert_not item.scheduled_for_deletion?
    end
  end

  test "native manual sync uses the exact shared connection and leaves the legacy item untouched" do
    with_mercury_context do |item, actor|
      sign_in actor
      connection = create_provider_connection(family: item.family, provider_key: "mercury")
      control = ProviderMigrationControl.create!(family: item.family, provider_key: "mercury", legacy_type: "MercuryItem", legacy_id: item.id,
        state: "active", provider_connection: connection)
      ProviderMigrationMapping.create!(family: item.family, provider_migration_control: control, role: "connection",
        legacy_type: "MercuryItem", legacy_id: item.id, provider_connection: connection)
      Provider::Mercury.expects(:new).never
      assert_difference -> { connection.syncs.count }, 1 do
        assert_no_difference -> { item.syncs.count } do
          post sync_mercury_item_path(item), as: :json
        end
      end
      assert_response :success
    end
  end

  test "nonadmin cannot manage a legacy connection" do
    with_mercury_context do |item, actor|
      actor.update!(role: "member")
      sign_in actor
      Provider::Mercury.expects(:new).never
      post sync_mercury_item_path(item)
      assert_response :redirect
      assert_empty item.syncs
      get select_accounts_mercury_items_path, params: { mercury_item_id: item.id }
      assert_response :redirect
      assert_empty item.mercury_accounts
    end
  end
end
