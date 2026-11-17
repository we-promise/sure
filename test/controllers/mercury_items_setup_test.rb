require "test_helper"

# Mercury's account setup imports and completes as the provider kit does.
class MercuryItemsSetupTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @item = mercury_items(:one)
    @account = mercury_accounts(:checking_account)
  end

  test "the setup page fetches accounts even when the connection already has some" do
    stub_accounts([ { id: "acc_new", name: "Fresh savings" } ])

    get setup_accounts_mercury_item_url(@item)

    assert_response :success
    assert_includes response.body, "Fresh savings"
    assert @item.mercury_accounts.exists?(account_id: "acc_new")
  end

  test "the setup page refreshes an imported account the provider now reports differently" do
    account = @item.mercury_accounts.create!(account_id: "acc_x", name: "Old name", currency: "USD", raw_payload: { "id" => "acc_x", "name" => "Old name" })
    stub_accounts([ { id: "acc_x", name: "New name" } ])

    get setup_accounts_mercury_item_url(@item)

    assert_equal "New name", account.reload.name
  end

  test "the setup page leaves an imported account alone when the provider reports it unchanged" do
    account = @item.mercury_accounts.create!(account_id: "acc_x", name: "Old name", currency: "USD", raw_payload: { "id" => "acc_x", "name" => "Old name" })
    account.update_column(:name, "Kept locally")
    stub_accounts([ { id: "acc_x", name: "Old name" } ])

    get setup_accounts_mercury_item_url(@item)

    assert_equal "Kept locally", account.reload.name
  end

  test "an unexpected fetch error shows the translated message, not the raw one" do
    MercuryItem.any_instance.stubs(:mercury_provider).raises(StandardError, "raw internal detail")

    get setup_accounts_mercury_item_url(@item)

    assert_includes response.body, I18n.t("mercury_items.setup_accounts.api_error", message: I18n.t("mercury_items.errors.unexpected_error"))
    assert_not_includes response.body, "raw internal detail"
  end

  test "without an API key the setup page says so" do
    @item.update_column(:token, "")

    get setup_accounts_mercury_item_url(@item)

    assert_includes response.body, I18n.t("mercury_items.setup_accounts.no_api_token")
  end

  test "completing with nothing to create redirects with an alert and no stream" do
    post complete_account_setup_mercury_item_url(@item), params: {}, headers: { "Turbo-Frame" => "modal" }

    assert_redirected_to accounts_path
    assert_equal I18n.t("mercury_items.complete_account_setup.no_accounts"), flash[:alert]
  end

  test "an unsupported account type counts as skipped" do
    assert_no_difference "Account.count" do
      post complete_account_setup_mercury_item_url(@item), params: { account_types: { @account.id => "Investment" } }
    end

    assert_redirected_to accounts_path
    assert_equal I18n.t("mercury_items.complete_account_setup.all_skipped"), flash[:alert]
  end

  test "a depository with no subtype chosen is created as checking" do
    post complete_account_setup_mercury_item_url(@item), params: { account_types: { @account.id => "Depository" } }

    assert_equal "checking", @account.reload.account.accountable.subtype
  end

  test "a subtype the account type doesn't have is dropped" do
    post complete_account_setup_mercury_item_url(@item), params: {
      account_types: { @account.id => "Depository" },
      account_subtypes: { @account.id => "not_a_subtype" }
    }

    assert_equal "checking", @account.reload.account.accountable.subtype
  end

  test "a chosen valid subtype is kept" do
    post complete_account_setup_mercury_item_url(@item), params: {
      account_types: { @account.id => "Depository" },
      account_subtypes: { @account.id => "savings" }
    }

    assert_equal "savings", @account.reload.account.accountable.subtype
  end

  test "completing inside a Turbo frame streams the card and accounts" do
    post complete_account_setup_mercury_item_url(@item),
      params: { account_types: { @account.id => "Depository" } },
      headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_turbo_stream action: "replace", target: ActionView::RecordIdentifier.dom_id(@item)
    assert_turbo_stream action: "update", target: "manual-accounts"
  end

  test "one account failing doesn't undo the others" do
    second = @item.mercury_accounts.create!(account_id: "acc_second", name: "Second", currency: "USD")
    original = Account.method(:create_and_sync)
    failing_second = ->(attributes, **options) do
      raise ActiveRecord::RecordInvalid.new(Account.new) if attributes[:name] == "Second"

      original.call(attributes, **options)
    end

    Account.stub(:create_and_sync, failing_second) do
      post complete_account_setup_mercury_item_url(@item), params: {
        account_types: { @account.id => "Depository", second.id => "Depository" }
      }
    end

    assert @account.reload.account_provider.present?
    assert_nil second.reload.account_provider
    assert_equal I18n.t("mercury_items.complete_account_setup.partial_success", created_count: 1, failed_count: 1), flash[:alert]
  end

  private
    def stub_accounts(accounts)
      provider = mock("mercury_provider")
      provider.stubs(:get_accounts).returns(accounts: accounts)
      MercuryItem.any_instance.stubs(:mercury_provider).returns(provider)
    end
end
