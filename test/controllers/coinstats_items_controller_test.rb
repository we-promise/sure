require "test_helper"

class CoinstatsItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @coinstats_item = CoinstatsItem.create!(
      family: @family,
      name: "Test CoinStats Connection",
      api_key: "test_api_key_123"
    )
  end

  # Helper to wrap data in Provider::Response
  def success_response(data)
    Provider::Response.new(success?: true, data: data, error: nil)
  end

  def error_response(message)
    Provider::Response.new(success?: false, data: nil, error: Provider::Error.new(message))
  end

  test "should get new" do
    get new_coinstats_item_url
    assert_response :success
  end

  test "should create coinstats item with valid api key" do
    # Mock the API key validation
    Provider::Coinstats.any_instance.expects(:get_blockchains).returns(success_response([])).once

    assert_difference("CoinstatsItem.count", 1) do
      post coinstats_items_url, params: {
        coinstats_item: {
          name: "New CoinStats Connection",
          api_key: "valid_api_key"
        }
      }
    end
  end

  test "should not create coinstats item with invalid api key" do
    # Mock the API key validation to fail
    Provider::Coinstats.any_instance.expects(:get_blockchains)
      .returns(error_response("Invalid API key"))

    assert_no_difference("CoinstatsItem.count") do
      post coinstats_items_url, params: {
        coinstats_item: {
          name: "New CoinStats Connection",
          api_key: "invalid_api_key"
        }
      }
    end
  end

  test "should destroy coinstats item" do
    # Schedules for deletion, doesn't actually delete immediately
    assert_no_difference("CoinstatsItem.count") do
      delete coinstats_item_url(@coinstats_item)
    end

    assert_redirected_to settings_providers_path
    @coinstats_item.reload
    assert @coinstats_item.scheduled_for_deletion?
  end

  test "should sync coinstats item" do
    post sync_coinstats_item_url(@coinstats_item)
    assert_redirected_to accounts_path
  end

  test "sync responds to json format" do
    post sync_coinstats_item_url(@coinstats_item, format: :json)
    assert_response :ok
  end

  test "should update coinstats item with valid api key" do
    Provider::Coinstats.any_instance.expects(:get_blockchains).returns(success_response([])).once

    patch coinstats_item_url(@coinstats_item), params: {
      coinstats_item: {
        name: "Updated Name",
        api_key: "new_valid_api_key"
      }
    }

    @coinstats_item.reload
    assert_equal "Updated Name", @coinstats_item.name
  end

  test "should not update coinstats item with invalid api key" do
    Provider::Coinstats.any_instance.expects(:get_blockchains)
      .returns(error_response("Invalid API key"))

    original_name = @coinstats_item.name

    patch coinstats_item_url(@coinstats_item), params: {
      coinstats_item: {
        name: "Updated Name",
        api_key: "invalid_api_key"
      }
    }

    @coinstats_item.reload
    assert_equal original_name, @coinstats_item.name
  end

  test "link_wallet requires all parameters" do
    post link_wallet_coinstats_items_url, params: {
      coinstats_item_id: @coinstats_item.id,
      address: "0x123"
      # missing blockchain
    }

    assert_response :unprocessable_entity
  end

  test "link_wallet with valid params creates accounts" do
    balance_data = [
      { coinId: "ethereum", name: "Ethereum", symbol: "ETH", amount: 1.5, price: 2000 }
    ]

    bulk_response = [
      { blockchain: "ethereum", address: "0x123abc", connectionId: "ethereum", balances: balance_data }
    ]

    Provider::Coinstats.any_instance.expects(:get_wallet_balances)
      .with("ethereum:0x123abc")
      .returns(success_response(bulk_response))

    Provider::Coinstats.any_instance.expects(:extract_wallet_balance)
      .with(bulk_response, "0x123abc", "ethereum")
      .returns(balance_data)

    assert_difference("Account.count", 1) do
      assert_difference("CoinstatsAccount.count", 1) do
        post link_wallet_coinstats_items_url, params: {
          coinstats_item_id: @coinstats_item.id,
          address: "0x123abc",
          blockchain: "ethereum"
        }
      end
    end

    assert_redirected_to accounts_path
  end

  test "link_wallet handles provider errors" do
    Provider::Coinstats.any_instance.expects(:get_wallet_balances)
      .raises(Provider::Coinstats::Error.new("Invalid API key"))

    post link_wallet_coinstats_items_url, params: {
      coinstats_item_id: @coinstats_item.id,
      address: "0x123abc",
      blockchain: "ethereum"
    }

    assert_response :unprocessable_entity
  end

  test "link_wallet handles no tokens found" do
    Provider::Coinstats.any_instance.expects(:get_wallet_balances)
      .returns(success_response([]))

    Provider::Coinstats.any_instance.expects(:extract_wallet_balance)
      .returns([])

    post link_wallet_coinstats_items_url, params: {
      coinstats_item_id: @coinstats_item.id,
      address: "0x123abc",
      blockchain: "ethereum"
    }

    assert_response :unprocessable_entity
    assert_match(/No tokens found/, response.body)
  end
end
