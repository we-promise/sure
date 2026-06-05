require "test_helper"

class AkahuItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)

    @family = families(:dylan_family)
    @akahu_item = AkahuItem.create!(
      family: @family,
      name: "Main Akahu",
      app_token: "akahu-app-credential",
      user_token: "akahu-user-credential"
    )
    @akahu_account = @akahu_item.akahu_accounts.create!(
      name: "Akahu Checking",
      account_id: "acc_123",
      currency: "NZD"
    )
    @account = accounts(:depository)
  end

  test "setup_accounts preselects mapped account type for each account" do
    AkahuItemsController.any_instance.stubs(:fetch_akahu_accounts_from_api).returns(nil)

    @akahu_account.update!(account_type: "SAVINGS")
    get setup_accounts_akahu_item_url(@akahu_item)
    assert_response :success

    selected_option = css_select("select[name='account_types[#{@akahu_account.id}]'] option[selected='selected']").first
    assert_equal "Depository", selected_option["value"]

    @akahu_account.update!(account_type: "FOREIGN")
    get setup_accounts_akahu_item_url(@akahu_item)
    assert_response :success
    selected_option = css_select("select[name='account_types[#{@akahu_account.id}]'] option[selected='selected']").first
    assert_equal "skip", selected_option["value"]
  end

  test "complete_account_setup uses Akahu account type suggestion subtype for investment accounts" do
    @akahu_account.update!(account_type: "KIWISAVER")

    assert_difference "Account.count", 1 do
      assert_difference "AccountProvider.count", 1 do
        post complete_account_setup_akahu_item_url(@akahu_item), params: {
          account_types: { @akahu_account.id.to_s => "Investment" }
        }
      end
    end

    assert_redirected_to accounts_path
    @akahu_account.reload
    created_account = @akahu_account.current_account
    assert_not_nil created_account
    assert_equal "Investment", created_account.accountable_type
    assert_equal "retirement", created_account.accountable.subtype
  end

  test "select accounts rejects unsafe return paths" do
    AkahuItemsController.any_instance.stubs(:fetch_akahu_accounts_from_api).returns(nil)

    unsafe_return_paths.each do |return_to|
      get select_accounts_akahu_items_url, params: {
        akahu_item_id: @akahu_item.id,
        accountable_type: "Depository",
        return_to: return_to
      }

      assert_response :success
      assert_select %(input[name="return_to"]) do |fields|
        assert fields.first["value"].blank?
      end
    end
  end

  test "select existing account rejects unsafe return paths" do
    AkahuItemsController.any_instance.stubs(:fetch_akahu_accounts_from_api).returns(nil)

    unsafe_return_paths.each do |return_to|
      get select_existing_account_akahu_items_url, params: {
        account_id: @account.id,
        akahu_item_id: @akahu_item.id,
        return_to: return_to
      }

      assert_response :success
      assert_select %(input[name="return_to"]) do |fields|
        assert fields.first["value"].blank?
      end
    end
  end

  test "select existing account preserves safe local return path" do
    return_to = "/accounts?tab=manual"
    AkahuItemsController.any_instance.stubs(:fetch_akahu_accounts_from_api).returns(nil)

    get select_existing_account_akahu_items_url, params: {
      account_id: @account.id,
      akahu_item_id: @akahu_item.id,
      return_to: return_to
    }

    assert_response :success
    assert_select %(input[name="return_to"][value="#{return_to}"])
  end

  test "link accounts rejects unsafe return path on no selection redirect" do
    post link_accounts_akahu_items_url, params: {
      akahu_item_id: @akahu_item.id,
      accountable_type: "Depository",
      return_to: "https://evil.example/accounts"
    }

    assert_redirected_to select_accounts_akahu_items_path(
      akahu_item_id: @akahu_item.id,
      accountable_type: "Depository",
      return_to: nil
    )
  end

  test "link accounts rejects unsafe return path after linking" do
    @akahu_account.update!(current_balance: 10)

    assert_difference "AccountProvider.count", 1 do
      post link_accounts_akahu_items_url, params: {
        akahu_item_id: @akahu_item.id,
        account_ids: [ @akahu_account.id ],
        accountable_type: "Depository",
        return_to: "https://evil.example/accounts"
      }
    end

    assert_redirected_to accounts_path
  end

  test "link existing account rejects unsafe return paths" do
    unsafe_return_paths.each_with_index do |return_to, index|
      account = @family.accounts.create!(
        name: "Manual Checking #{index}",
        balance: 0,
        currency: "NZD",
        accountable: Depository.new
      )
      akahu_account = @akahu_item.akahu_accounts.create!(
        name: "Akahu Checking #{index}",
        account_id: "acc_unsafe_#{index}",
        currency: "NZD"
      )

      assert_difference "AccountProvider.count", 1 do
        post link_existing_account_akahu_items_url, params: {
          account_id: account.id,
          akahu_item_id: @akahu_item.id,
          akahu_account_id: akahu_account.id,
          return_to: return_to
        }
      end

      assert_redirected_to accounts_path
    end
  end

  test "preload accounts uses requested Akahu connection" do
    second_item = AkahuItem.create!(
      family: @family,
      name: "Secondary Akahu",
      app_token: "akahu-app-credential-2",
      user_token: "akahu-user-credential-2"
    )

    AkahuItemsController.any_instance
      .expects(:fetch_akahu_accounts_from_api)
      .with(second_item)
      .returns(nil)

    get preload_accounts_akahu_items_url, params: { akahu_item_id: second_item.id }, as: :json

    assert_response :success
    assert_equal false, JSON.parse(response.body)["has_accounts"]
  end

  test "select accounts uses requested Akahu connection" do
    second_item = AkahuItem.create!(
      family: @family,
      name: "Secondary Akahu",
      app_token: "akahu-app-credential-2",
      user_token: "akahu-user-credential-2"
    )
    second_item.akahu_accounts.create!(
      name: "Secondary Checking",
      account_id: "acc_secondary",
      currency: "NZD"
    )
    AkahuItemsController.any_instance.stubs(:fetch_akahu_accounts_from_api).returns(nil)

    get select_accounts_akahu_items_url, params: { akahu_item_id: second_item.id, accountable_type: "Depository" }

    assert_response :success
    assert_includes response.body, "Secondary Checking"
    refute_includes response.body, "Akahu Checking"
  end

  test "link accounts uses requested Akahu connection" do
    second_item = AkahuItem.create!(
      family: @family,
      name: "Secondary Akahu",
      app_token: "akahu-app-credential-2",
      user_token: "akahu-user-credential-2"
    )
    second_account = second_item.akahu_accounts.create!(
      name: "Secondary Checking",
      account_id: "acc_secondary",
      currency: "NZD",
      current_balance: 42
    )

    assert_difference "Account.count", 1 do
      assert_difference "AccountProvider.count", 1 do
        post link_accounts_akahu_items_url, params: {
          akahu_item_id: second_item.id,
          account_ids: [ second_account.id ],
          accountable_type: "Depository"
        }
      end
    end

    assert_redirected_to accounts_path
    assert_equal second_account.id, AccountProvider.order(:created_at).last.provider_id
    assert_nil @akahu_account.reload.current_account
  end

  test "select existing account uses requested Akahu connection" do
    second_item = AkahuItem.create!(
      family: @family,
      name: "Secondary Akahu",
      app_token: "akahu-app-credential-2",
      user_token: "akahu-user-credential-2"
    )
    second_item.akahu_accounts.create!(
      name: "Secondary Checking",
      account_id: "acc_secondary",
      currency: "NZD"
    )
    AkahuItemsController.any_instance.stubs(:fetch_akahu_accounts_from_api).returns(nil)

    get select_existing_account_akahu_items_url, params: {
      account_id: @account.id,
      akahu_item_id: second_item.id
    }

    assert_response :success
    assert_includes response.body, "Secondary Checking"
    refute_includes response.body, "Akahu Checking"
  end

  test "complete account setup hides raw creation errors from users" do
    raw_message = "raw provider failure with akahu-user-credential"
    AkahuItemsController.any_instance
      .stubs(:create_account_from_akahu)
      .raises(ActiveRecord::RecordNotSaved.new(raw_message))

    post complete_account_setup_akahu_item_url(@akahu_item), params: {
      account_types: { @akahu_account.id.to_s => "Depository" }
    }

    assert_redirected_to accounts_path
    assert_equal I18n.t("akahu_items.complete_account_setup.creation_failed"), flash[:alert]
    refute_includes flash[:alert], raw_message
  end

  private

    def unsafe_return_paths
      [
        "https://evil.example/accounts",
        "http://evil.example/accounts",
        "//evil.example/accounts",
        "\\evil.example/accounts",
        "/\\evil.example/accounts",
        "/%2fevil.example/accounts",
        "/%2Fevil.example/accounts",
        "/%5cevil.example/accounts",
        "/%5Cevil.example/accounts",
        "/\naccounts",
        "/ accounts",
        "   "
      ]
    end
end
