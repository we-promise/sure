require "test_helper"

class Trading212ItemTest < ActiveSupport::TestCase
  include SyncableInterfaceTest

  setup do
    @family = families(:dylan_family)
    @trading212_item = @syncable = trading212_items(:configured_item)
  end

  # === Validations ===

  test "validates presence of api_key on create" do
    item = Trading212Item.new(family: @family, api_secret: "secret", environment: "live")
    assert_not item.valid?
    assert_includes item.errors[:api_key], "can't be blank"
  end

  test "validates presence of api_secret on create" do
    item = Trading212Item.new(family: @family, api_key: "key", environment: "live")
    assert_not item.valid?
    assert_includes item.errors[:api_secret], "can't be blank"
  end

  test "validates api_key and api_secret on create" do
    item = Trading212Item.new(family: @family, api_key: "key", api_secret: "secret")
    assert item.valid?
  end

  # === Status enum ===

  test "default status is good" do
    item = Trading212Item.new(family: @family, api_key: "key", api_secret: "secret")
    assert_equal "good", item.status
  end

  test "can query good items" do
    items = Trading212Item.good
    assert_includes items, @trading212_item
    assert_not_includes items, trading212_items(:requires_update_item)
  end

  test "can query requires_update items" do
    items = Trading212Item.needs_update
    assert_includes items, trading212_items(:requires_update_item)
    assert_not_includes items, @trading212_item
  end

  # === Environment enum ===

  test "default environment is live" do
    item = Trading212Item.new(family: @family, api_key: "key", api_secret: "secret")
    assert_equal "live", item.environment
  end

  test "accepts demo environment" do
    item = Trading212Item.new(family: @family, api_key: "key", api_secret: "secret", environment: "demo")
    assert item.valid?
    assert_equal "demo", item.environment
  end

  # === credentials_configured? ===

  test "credentials_configured? returns true when api_key and api_secret are present" do
    assert @trading212_item.credentials_configured?
  end

  test "credentials_configured? returns false when api_key is blank" do
    item = trading212_items(:no_credentials_item)
    assert_not item.credentials_configured?
  end

  # === trading212_provider ===

  test "trading212_provider returns a Provider::Trading212 instance when configured" do
    provider = @trading212_item.trading212_provider
    assert_instance_of Provider::Trading212, provider
  end

  test "trading212_provider returns nil when credentials not configured" do
    item = trading212_items(:no_credentials_item)
    assert_nil item.trading212_provider
  end

  test "trading212_provider raises ConfigurationError with blank api_key" do
    assert_raises(Provider::Trading212::ConfigurationError) do
      Trading212Item.new(
        family: @family,
        api_key: "",
        api_secret: "secret"
      ).trading212_provider
    end
  end

  # === Scopes ===

  test "active scope excludes items scheduled for deletion" do
    item = trading212_items(:configured_item)
    item.update!(scheduled_for_deletion: true)

    assert_not_includes Trading212Item.active, item
  end

  test "syncable scope excludes items without api_key" do
    assert_not_includes Trading212Item.syncable, trading212_items(:no_credentials_item)
  end

  test "syncable scope includes items with credentials" do
    assert_includes Trading212Item.syncable, @trading212_item
  end

  # === destroy_later ===

  test "destroy_later marks item for deletion and enqueues DestroyJob" do
    assert_enqueued_with(job: DestroyJob) do
      @trading212_item.destroy_later
    end

    assert_predicate @trading212_item.reload, :scheduled_for_deletion?
  end

  # === accounts ===

  test "accounts returns linked investment accounts" do
    trading212_account = trading212_accounts(:main_account)
    investment = accounts(:investment)

    trading212_account.ensure_account_provider!(investment)

    account_list = @trading212_item.accounts
    assert_includes account_list, investment
  end

  test "accounts returns empty when no accounts are linked" do
    assert_empty @trading212_item.accounts
  end

  # === has_completed_initial_setup? ===

  test "has_completed_initial_setup? returns false when no accounts exist" do
    assert_not @trading212_item.has_completed_initial_setup?
  end

  test "has_completed_initial_setup? returns true when accounts exist" do
    trading212_account = trading212_accounts(:main_account)
    investment = accounts(:investment)
    trading212_account.ensure_account_provider!(investment)

    assert @trading212_item.has_completed_initial_setup?
  end

  # === sync_status_summary ===

  test "sync_status_summary reports no_accounts when no trading212 accounts" do
    summary = @trading212_item.sync_status_summary
    assert_match(/no accounts/i, summary)
  end

  test "sync_status_summary reports all_linked when all accounts have providers" do
    trading212_account = trading212_accounts(:main_account)
    investment = accounts(:investment)
    trading212_account.ensure_account_provider!(investment)

    summary = @trading212_item.reload.sync_status_summary
    assert_match(/all linked/i, summary)
  end

  test "sync_status_summary reports partial when some accounts are unlinked" do
    # main_account is linked
    trading212_account = trading212_accounts(:main_account)
    investment = accounts(:investment)
    trading212_account.ensure_account_provider!(investment)

    # Create a second, unlinked account
    @trading212_item.trading212_accounts.create!(
      name: "Unlinked Account",
      trading212_account_id: "t212_acc_789",
      currency: "USD"
    )

    summary = @trading212_item.reload.sync_status_summary
    assert_match(/partial/i, summary)
  end

  # === unlink_all! ===

  test "unlink_all! removes account providers from all trading212 accounts" do
    trading212_account = trading212_accounts(:main_account)
    investment = accounts(:investment)
    trading212_account.ensure_account_provider!(investment)

    assert_difference -> { AccountProvider.where(provider_type: "Trading212Account").count }, -1 do
      @trading212_item.unlink_all!(dry_run: false)
    end
  end

  test "unlink_all! dry_run does not remove providers" do
    trading212_account = trading212_accounts(:main_account)
    investment = accounts(:investment)
    trading212_account.ensure_account_provider!(investment)

    assert_no_difference -> { AccountProvider.where(provider_type: "Trading212Account").count } do
      @trading212_item.unlink_all!(dry_run: true)
    end
  end
end
