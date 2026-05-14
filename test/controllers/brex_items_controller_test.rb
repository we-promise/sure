# frozen_string_literal: true

require "test_helper"

class BrexItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)

    @family = families(:dylan_family)
    clear_brex_cache_entries
    @existing_item = brex_items(:one)
    @second_item = BrexItem.create!(
      family: @family,
      name: "Business Brex",
      token: "second_brex_token",
      base_url: "https://api.brex.com"
    )
  end

  teardown do
    clear_brex_cache_entries
  end

  test "create adds a new brex connection without overwriting existing credentials" do
    existing_token = @existing_item.token

    assert_difference "BrexItem.count", 1 do
      post brex_items_url, params: {
        brex_item: {
          name: "Joint Brex",
          token: "joint_brex_token",
          base_url: "https://api.brex.com"
        }
      }
    end

    assert_redirected_to accounts_path
    assert_equal existing_token, @existing_item.reload.token
    assert_equal "joint_brex_token", @family.brex_items.find_by!(name: "Joint Brex").token
  end

  test "create uses localized default name when submitted name is blank" do
    assert_difference "BrexItem.count", 1 do
      post brex_items_url, params: {
        brex_item: {
          name: "  ",
          token: "default_name_token",
          base_url: "https://api.brex.com"
        }
      }
    end

    assert_redirected_to accounts_path
    assert_equal I18n.t("brex_items.default_connection_name"), @family.brex_items.order(:created_at).last.name
  end

  test "update changes only the selected brex connection" do
    existing_token = @existing_item.token

    patch brex_item_url(@second_item), params: {
      brex_item: {
        name: "Renamed Business Brex",
        token: "updated_second_token",
        base_url: "https://api-staging.brex.com"
      }
    }

    assert_redirected_to accounts_path
    assert_equal existing_token, @existing_item.reload.token
    assert_equal "Renamed Business Brex", @second_item.reload.name
    assert_equal "updated_second_token", @second_item.token
    assert_equal "https://api-staging.brex.com", @second_item.base_url
  end

  test "update rejects arbitrary brex base url" do
    patch brex_item_url(@second_item), params: {
      brex_item: {
        name: "Renamed Business Brex",
        token: "updated_second_token",
        base_url: "https://evil.example.test"
      }
    }

    assert_redirected_to settings_providers_path
    assert_includes flash[:alert], "https://api.brex.com"
    assert_equal "https://api.brex.com", @second_item.reload.base_url
    assert_equal "second_brex_token", @second_item.token
  end

  test "blank token update preserves the selected brex token" do
    original_token = @second_item.token

    patch brex_item_url(@second_item), params: {
      brex_item: {
        name: "Renamed Business Brex",
        token: "",
        base_url: "https://api.brex.com"
      }
    }

    assert_redirected_to accounts_path
    assert_equal "Renamed Business Brex", @second_item.reload.name
    assert_equal original_token, @second_item.token
  end

  test "update expires selected brex account cache when credentials change" do
    Rails.cache.expects(:delete).with(brex_cache_key(@existing_item)).never
    Rails.cache.expects(:delete).with(brex_cache_key(@second_item)).once

    patch brex_item_url(@second_item), params: {
      brex_item: {
        name: "Renamed Business Brex",
        token: "updated_second_token",
        base_url: "https://api-staging.brex.com"
      }
    }

    assert_redirected_to accounts_path
  end

  test "update does not expire selected brex account cache for name-only changes" do
    Rails.cache.expects(:delete).never

    patch brex_item_url(@second_item), params: {
      brex_item: {
        name: "Renamed Business Brex"
      }
    }

    assert_redirected_to accounts_path
    assert_equal "Renamed Business Brex", @second_item.reload.name
  end

  test "preload accounts uses selected brex item cache key" do
    Rails.cache.expects(:read).with(brex_cache_key(@second_item)).returns(nil)
    Rails.cache.expects(:write).with(brex_cache_key(@second_item), brex_accounts_payload, expires_in: 5.minutes)

    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: brex_accounts_payload)
    Provider::Brex.expects(:new)
      .with(@second_item.token, base_url: @second_item.effective_base_url)
      .returns(provider)

    get preload_accounts_brex_items_url, params: { brex_item_id: @second_item.id }, as: :json

    assert_response :success
    response = JSON.parse(@response.body)
    assert_equal true, response["success"]
    assert_equal true, response["has_accounts"]
  end

  test "select accounts requires an explicit connection when multiple brex items exist" do
    get select_accounts_brex_items_url, params: { accountable_type: "Depository" }

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("brex_items.select_accounts.select_connection"), flash[:alert]
  end

  test "select accounts renders the selected brex item id" do
    Rails.cache.expects(:read).with(brex_cache_key(@second_item)).returns(nil)
    Rails.cache.expects(:write).with(brex_cache_key(@second_item), brex_accounts_payload, expires_in: 5.minutes)

    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: brex_accounts_payload)
    Provider::Brex.expects(:new)
      .with(@second_item.token, base_url: @second_item.effective_base_url)
      .returns(provider)

    get select_accounts_brex_items_url, params: {
      brex_item_id: @second_item.id,
      accountable_type: "Depository"
    }

    assert_response :success
    assert_includes @response.body, %(name="brex_item_id")
    assert_includes @response.body, %(value="#{@second_item.id}")
  end

  test "select accounts rejects protocol relative return paths" do
    Rails.cache.expects(:read).with(brex_cache_key(@second_item)).returns(brex_accounts_payload)

    get select_accounts_brex_items_url, params: {
      brex_item_id: @second_item.id,
      accountable_type: "Depository",
      return_to: "//evil.example/accounts"
    }

    assert_response :success
    refute_includes @response.body, "//evil.example/accounts"
  end

  test "select accounts rejects backslash and unsafe local return paths" do
    [
      "/\\evil.example/accounts",
      "/%2fevil.example/accounts",
      "/%2Fevil.example/accounts",
      "/%5cevil.example/accounts",
      "/%5Cevil.example/accounts",
      "/\naccounts",
      "/ accounts",
      "/"
    ].each do |return_to|
      Rails.cache.expects(:read).with(brex_cache_key(@second_item)).returns(brex_accounts_payload)

      get select_accounts_brex_items_url, params: {
        brex_item_id: @second_item.id,
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
    account = @family.accounts.create!(
      name: "Manual Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    [
      "//evil.example/accounts",
      "\\evil.example/accounts",
      "/\\evil.example/accounts",
      "/%2fevil.example/accounts",
      "/%2Fevil.example/accounts",
      "/%5cevil.example/accounts",
      "/%5Cevil.example/accounts",
      "/\naccounts",
      "/ accounts",
      "   ",
      "/"
    ].each do |return_to|
      Rails.cache.expects(:read).with(brex_cache_key(@second_item)).returns(brex_accounts_payload)

      get select_existing_account_brex_items_url, params: {
        brex_item_id: @second_item.id,
        account_id: account.id,
        return_to: return_to
      }

      assert_response :success
      assert_select %(input[name="return_to"]) do |fields|
        assert fields.first["value"].blank?
      end
    end
  end

  test "select existing account preserves safe local return path" do
    account = @family.accounts.create!(
      name: "Manual Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    return_to = "/accounts?tab=manual"

    Rails.cache.expects(:read).with(brex_cache_key(@second_item)).returns(brex_accounts_payload)

    get select_existing_account_brex_items_url, params: {
      brex_item_id: @second_item.id,
      account_id: account.id,
      return_to: return_to
    }

    assert_response :success
    assert_select %(input[name="return_to"][value="#{return_to}"])
  end

  test "select existing account redirects when account id is invalid" do
    get select_existing_account_brex_items_url, params: {
      brex_item_id: @second_item.id,
      account_id: SecureRandom.uuid
    }

    assert_redirected_to accounts_path
    assert_equal I18n.t("brex_items.select_existing_account.no_account_specified"), flash[:alert]
  end

  test "select existing account renders the selected brex item id" do
    account = @family.accounts.create!(
      name: "Manual Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    Rails.cache.expects(:read).with(brex_cache_key(@second_item)).returns(nil)
    Rails.cache.expects(:write).with(brex_cache_key(@second_item), brex_accounts_payload, expires_in: 5.minutes)

    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: brex_accounts_payload)
    Provider::Brex.expects(:new)
      .with(@second_item.token, base_url: @second_item.effective_base_url)
      .returns(provider)

    get select_existing_account_brex_items_url, params: {
      brex_item_id: @second_item.id,
      account_id: account.id
    }

    assert_response :success
    assert_includes @response.body, %(name="brex_item_id")
    assert_includes @response.body, %(value="#{@second_item.id}")
  end

  test "link accounts uses selected brex item and allows duplicate upstream ids across items" do
    @existing_item.brex_accounts.create!(
      account_id: "shared_brex_account",
      name: "Shared Checking",
      currency: "USD",
      current_balance: 1000
    )

    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: brex_accounts_payload)
    Provider::Brex.expects(:new)
      .with(@second_item.token, base_url: @second_item.effective_base_url)
      .returns(provider)

    assert_difference -> { @second_item.brex_accounts.where(account_id: "shared_brex_account").count }, 1 do
      assert_difference "AccountProvider.count", 1 do
        post link_accounts_brex_items_url, params: {
          brex_item_id: @second_item.id,
          account_ids: [ "shared_brex_account" ],
          accountable_type: "Depository"
        }
      end
    end

    assert_redirected_to accounts_path
    assert_equal 1, @existing_item.brex_accounts.where(account_id: "shared_brex_account").count
  end

  test "link accounts does not silently use the first connection when multiple items exist" do
    assert_no_difference "BrexAccount.count" do
      assert_no_difference "Account.count" do
        post link_accounts_brex_items_url, params: {
          account_ids: [ "shared_brex_account" ],
          accountable_type: "Depository"
        }
      end
    end

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("brex_items.link_accounts.select_connection"), flash[:alert]
  end

  test "link existing account does not silently use the first connection when multiple items exist" do
    account = @family.accounts.create!(
      name: "Manual Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    assert_no_difference "BrexAccount.count" do
      assert_no_difference "AccountProvider.count" do
        post link_existing_account_brex_items_url, params: {
          account_id: account.id,
          brex_account_id: "shared_brex_account"
        }
      end
    end

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("brex_items.link_existing_account.select_connection"), flash[:alert]
  end

  test "link existing account requires account id" do
    assert_no_difference "AccountProvider.count" do
      post link_existing_account_brex_items_url, params: {
        brex_item_id: @second_item.id,
        brex_account_id: "shared_brex_account"
      }
    end

    assert_redirected_to accounts_path
    assert_equal I18n.t("brex_items.link_existing_account.no_account_specified"), flash[:alert]
  end

  test "link existing account redirects when account id is invalid" do
    assert_no_difference "AccountProvider.count" do
      post link_existing_account_brex_items_url, params: {
        brex_item_id: @second_item.id,
        account_id: SecureRandom.uuid,
        brex_account_id: "shared_brex_account"
      }
    end

    assert_redirected_to accounts_path
    assert_equal I18n.t("brex_items.link_existing_account.no_account_specified"), flash[:alert]
  end

  test "sync only queues a sync for the selected brex item" do
    assert_difference -> { Sync.where(syncable: @second_item).count }, 1 do
      assert_no_difference -> { Sync.where(syncable: @existing_item).count } do
        post sync_brex_item_url(@second_item)
      end
    end

    assert_response :redirect
  end

  test "complete account setup ignores unsupported account type and subtype params" do
    valid_brex_account = @second_item.brex_accounts.create!(
      account_id: "setup_valid",
      account_kind: "cash",
      name: "Setup Valid",
      currency: "USD",
      current_balance: 100
    )
    unsupported_brex_account = @second_item.brex_accounts.create!(
      account_id: "setup_unsupported",
      account_kind: "cash",
      name: "Setup Unsupported",
      currency: "USD",
      current_balance: 100
    )

    assert_difference "AccountProvider.count", 1 do
      post complete_account_setup_brex_item_url(@second_item), params: {
        account_types: {
          valid_brex_account.id => "Depository",
          unsupported_brex_account.id => "Investment",
          "not-a-brex-account" => "Depository"
        },
        account_subtypes: {
          valid_brex_account.id => "savings",
          unsupported_brex_account.id => "brokerage",
          "not-a-brex-account" => "checking"
        }
      }
    end

    assert_redirected_to accounts_path
    assert_equal "savings", valid_brex_account.reload.account.accountable.subtype
    assert_nil unsupported_brex_account.reload.account_provider
    assert_match(/skipped/i, flash[:notice])
  end

  test "complete account setup treats scalar setup params as empty" do
    assert_no_difference "AccountProvider.count" do
      post complete_account_setup_brex_item_url(@second_item), params: {
        account_types: "not-a-hash",
        account_subtypes: "also-not-a-hash"
      }
    end

    assert_redirected_to accounts_path
    assert_equal I18n.t("brex_items.complete_account_setup.no_accounts"), flash[:alert]
  end

  private

    def brex_accounts_payload
      [
        {
          id: "shared_brex_account",
          name: "Shared Checking",
          account_kind: "cash",
          status: "active",
          current_balance: { amount: 100_000, currency: "USD" },
          available_balance: { amount: 95_000, currency: "USD" }
        }
      ]
    end

    def brex_cache_key(brex_item)
      BrexItem::AccountFlow.cache_key(@family, brex_item)
    end

    def clear_brex_cache_entries
      return unless defined?(@family) && @family.present?
      return unless Rails.cache.respond_to?(:delete_matched)

      Rails.cache.delete_matched("brex_accounts_#{@family.id}_*")
    rescue NotImplementedError
      # Some test cache stores do not implement delete_matched; tests that depend
      # on cache state stub exact Brex cache keys instead of relying on globals.
    end
end
