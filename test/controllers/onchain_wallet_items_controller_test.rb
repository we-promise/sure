require "test_helper"

class OnchainWalletItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
  end

  test "new wallet renders account modal form" do
    get new_wallet_onchain_wallet_items_path, headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_select "turbo-frame#modal"
    assert_select "select[name='chain'] option[value='bitcoin']", text: "Bitcoin"
    assert_select "select[name='chain'] option[value='ethereum']", text: "Ethereum"
    assert_select "input[name='wallet_address']"
  end

  test "new wallet renders the link form" do
    get new_wallet_onchain_wallet_items_path, headers: { "Turbo-Frame" => "modal" }

    assert_response :success
  end

  test "link wallet from modal imports Bitcoin wallet and redirects to accounts" do
    address = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

    Provider::MempoolSpace.any_instance.stubs(:valid_address?).returns(true)
    Provider::MempoolSpace.any_instance.stubs(:get_address).returns({
      "chain_stats" => { "funded_txo_sum" => 100_000_000, "spent_txo_sum" => 0 },
      "mempool_stats" => { "funded_txo_sum" => 0, "spent_txo_sum" => 0 }
    })
    Provider::MempoolSpace.any_instance.stubs(:get_address_txs).returns([])
    Provider::MempoolSpace.any_instance.stubs(:get_mempool_txs).returns([])
    OnchainWalletAccount::SecurityResolver.stubs(:resolve).returns(nil)
    OnchainWalletItem.any_instance.stubs(:process_accounts).returns([])
    existing_account_ids = Account.ids

    assert_difference -> { OnchainWalletItem.count }, 1 do
      assert_difference -> { OnchainWalletAccount.count }, 1 do
        assert_difference -> { AccountProvider.count }, 1 do
          assert_difference -> { Account.count }, 1 do
            post link_wallet_onchain_wallet_items_path,
                 params: { source: "account_modal", chain: "bitcoin", wallet_address: address },
                 as: :turbo_stream,
                 headers: { "Turbo-Frame" => "modal" }
          end
        end
      end
    end

    assert_response :success
    assert_match %r{<turbo-stream action="redirect" target="/accounts">}, response.body
    assert_equal "Wallet linked.", flash[:notice]

    created_account = Account.where.not(id: existing_account_ids).first
    assert_equal "Crypto", created_account.accountable_type
    assert_equal "wallet", created_account.accountable.subtype
  end

  test "missing address from modal re-renders modal error" do
    post link_wallet_onchain_wallet_items_path,
         params: { source: "account_modal", chain: "bitcoin", wallet_address: "" },
         as: :turbo_stream,
         headers: { "Turbo-Frame" => "modal" }

    assert_response :unprocessable_entity
    assert_match %r{<turbo-stream action="replace" target="modal">}, response.body
    assert_match "Wallet address is required.", response.body
  end

  test "unsupported chain from modal re-renders modal error" do
    post link_wallet_onchain_wallet_items_path,
         params: { source: "account_modal", chain: "dogecoin", wallet_address: "wallet" },
         as: :turbo_stream,
         headers: { "Turbo-Frame" => "modal" }

    assert_response :unprocessable_entity
    assert_match %r{<turbo-stream action="replace" target="modal">}, response.body
    assert_match "Choose a supported blockchain.", response.body
  end

  test "link Ethereum wallet works without an API key (keyless via Blockscout)" do
    address = "0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae"

    Provider::Blockscout.any_instance.stubs(:valid_address?).returns(true)
    Provider::Blockscout.any_instance.stubs(:get_native_balance).returns("1000000000000000000")
    Provider::Blockscout.any_instance.stubs(:get_normal_transactions).returns([])
    Provider::Blockscout.any_instance.stubs(:get_erc20_transfers).returns([])
    OnchainWalletAccount::SecurityResolver.stubs(:resolve).returns(nil)

    assert_difference -> { OnchainWalletAccount.where(chain: "ethereum").count }, 1 do
      post link_wallet_onchain_wallet_items_path,
           params: { source: "account_modal", chain: "ethereum", wallet_address: address },
           as: :turbo_stream,
           headers: { "Turbo-Frame" => "modal" }
    end

    assert_response :success
  end

  test "link Ethereum wallet uses Etherscan when selected" do
    @family.onchain_wallet_items.create!(
      name: "On-chain Wallets",
      ethereum_data_provider: "etherscan",
      etherscan_api_key: "key"
    )
    address = "0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae"

    Provider::Etherscan.any_instance.stubs(:valid_address?).returns(true)
    Provider::Etherscan.any_instance.stubs(:get_native_balance).returns("1000000000000000000")
    Provider::Etherscan.any_instance.stubs(:get_normal_transactions).returns([])
    Provider::Etherscan.any_instance.stubs(:get_erc20_transfers).returns([])
    OnchainWalletAccount::SecurityResolver.stubs(:resolve).returns(nil)

    assert_difference -> { OnchainWalletAccount.where(chain: "ethereum").count }, 1 do
      post link_wallet_onchain_wallet_items_path,
           params: { source: "account_modal", chain: "ethereum", wallet_address: address },
           as: :turbo_stream,
           headers: { "Turbo-Frame" => "modal" }
    end
  end

  test "Ethereum first submit renders token review with priced tokens preselected" do
    item = @family.onchain_wallet_items.create!(name: "On-chain Wallets", etherscan_api_key: "key")
    address = "0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae"
    usdc_contract = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
    scam_contract = "0x1111111111111111111111111111111111111111"
    security = Security.create!(
      ticker: "USDCUSD",
      exchange_operating_mic: Provider::BinancePublic::BINANCE_MIC,
      price_provider: "binance_public"
    )
    security.prices.create!(date: Date.current, price: 1, currency: "USD")

    Provider::Blockscout.any_instance.stubs(:valid_address?).returns(true)
    Provider::Blockscout.any_instance.stubs(:get_native_balance).returns("1000000000000000000")
    Provider::Blockscout.any_instance.stubs(:get_normal_transactions).returns([])
    Provider::Blockscout.any_instance.stubs(:get_erc20_transfers).returns([
      erc20_transfer(address: address, contract: usdc_contract, symbol: "USDC", name: "USD Coin", decimals: "6", value: "5000000"),
      erc20_transfer(address: address, contract: scam_contract, symbol: "SCAM", name: "Visit scam.example", decimals: "18", value: "1000000000000000000000")
    ])
    OnchainWalletAccount::SecurityResolver.stubs(:resolve).with("ETH", "ETH").returns(nil)
    OnchainWalletAccount::SecurityResolver.stubs(:resolve).with("USDC", "USDC").returns(security)
    OnchainWalletAccount::SecurityResolver.stubs(:resolve).with("SCAM", "SCAM").returns(nil)

    assert_no_difference -> { OnchainWalletAccount.count } do
      post link_wallet_onchain_wallet_items_path,
           params: { source: "account_modal", chain: "ethereum", wallet_address: address },
           as: :turbo_stream,
           headers: { "Turbo-Frame" => "modal" }
    end

    assert_response :success
    assert_match %r{<turbo-stream action="replace" target="modal">}, response.body
    assert_match "Review Ethereum tokens", response.body
    assert_select "input[name='selected_token_contracts[]'][value='#{usdc_contract}'][checked='checked']"
    assert_select "input[name='selected_token_contracts[]'][value='#{scam_contract}'][checked='checked']", count: 0
  end

  test "Ethereum review confirmation imports native ETH and selected tokens only" do
    @family.onchain_wallet_items.create!(name: "On-chain Wallets", etherscan_api_key: "key")
    address = "0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae"
    usdc_contract = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
    scam_contract = "0x1111111111111111111111111111111111111111"

    Provider::Blockscout.any_instance.stubs(:valid_address?).returns(true)
    Provider::Blockscout.any_instance.stubs(:get_native_balance).returns("1000000000000000000")
    Provider::Blockscout.any_instance.stubs(:get_normal_transactions).returns([])
    Provider::Blockscout.any_instance.stubs(:get_erc20_transfers).returns([
      erc20_transfer(address: address, contract: usdc_contract, symbol: "USDC", name: "USD Coin", decimals: "6", value: "5000000"),
      erc20_transfer(address: address, contract: scam_contract, symbol: "SCAM", name: "Visit scam.example", decimals: "18", value: "1000000000000000000000")
    ])
    OnchainWalletAccount::SecurityResolver.stubs(:resolve).returns(nil)
    OnchainWalletItem.any_instance.stubs(:process_accounts).returns([])

    assert_difference -> { OnchainWalletAccount.count }, 2 do
      post link_wallet_onchain_wallet_items_path,
           params: {
             source: "account_modal",
             chain: "ethereum",
             wallet_address: address,
             reviewed_tokens: "1",
             selected_token_contracts: [ usdc_contract ]
           },
           as: :turbo_stream,
           headers: { "Turbo-Frame" => "modal" }
    end

    assert_response :success
    assert OnchainWalletAccount.exists?(chain: "ethereum", wallet_address: address, asset_kind: "native", symbol: "ETH")
    assert OnchainWalletAccount.exists?(chain: "ethereum", wallet_address: address, asset_kind: "erc20", token_contract: usdc_contract)
    assert_not OnchainWalletAccount.exists?(chain: "ethereum", wallet_address: address, asset_kind: "erc20", token_contract: scam_contract)
  end

  test "settings panel requests still replace onchain provider panel" do
    post link_wallet_onchain_wallet_items_path,
         params: { chain: "dogecoin", wallet_address: "wallet" },
         as: :turbo_stream,
         headers: { "Turbo-Frame" => "onchain_wallet-connect-form" }

    assert_response :unprocessable_entity
    assert_match %r{<turbo-stream action="replace" target="onchain-wallet-providers-panel">}, response.body
    assert_match "Choose a supported blockchain.", response.body
  end

  test "manage renders connected wallet addresses in modal" do
    item = @family.onchain_wallet_items.create!(name: "On-chain Wallets")
    item.onchain_wallet_accounts.create!(
      chain: "ethereum",
      wallet_address: "0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae",
      asset_kind: "native",
      symbol: "ETH",
      name: "Ethereum",
      currency: "USD"
    )
    item.onchain_wallet_accounts.create!(
      chain: "ethereum",
      wallet_address: "0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae",
      asset_kind: "erc20",
      token_contract: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      symbol: "USDC",
      name: "USD Coin",
      currency: "USD"
    )

    get manage_onchain_wallet_item_path(item), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_select "turbo-frame#modal"
    assert_match "Manage On-chain Wallets", response.body
    assert_match "0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae", response.body
    assert_match new_wallet_onchain_wallet_items_path, response.body
  end

  test "edit wallet renders edit form modal" do
    item = @family.onchain_wallet_items.create!(name: "On-chain Wallets")
    address = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"
    item.onchain_wallet_accounts.create!(
      chain: "bitcoin",
      wallet_address: address,
      asset_kind: "native",
      symbol: "BTC",
      name: "Bitcoin",
      currency: "USD"
    )

    get edit_wallet_onchain_wallet_item_path(item, chain: "bitcoin", wallet_address: address),
        headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_select "turbo-frame#modal"
    assert_match "Edit wallet address", response.body
    assert_match address, response.body
    assert_select "input[name='old_wallet_address'][value='#{address}']"
  end

  test "update wallet swaps Bitcoin address and re-imports" do
    item = @family.onchain_wallet_items.create!(name: "On-chain Wallets")
    old_address = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"
    new_address = "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq"
    wallet_account = item.onchain_wallet_accounts.create!(
      chain: "bitcoin",
      wallet_address: old_address,
      asset_kind: "native",
      symbol: "BTC",
      name: "Bitcoin",
      currency: "USD"
    )

    Provider::MempoolSpace.any_instance.stubs(:valid_address?).returns(true)
    Provider::MempoolSpace.any_instance.stubs(:get_address).returns({
      "chain_stats" => { "funded_txo_sum" => 200_000_000, "spent_txo_sum" => 0 },
      "mempool_stats" => { "funded_txo_sum" => 0, "spent_txo_sum" => 0 }
    })
    Provider::MempoolSpace.any_instance.stubs(:get_address_txs).returns([])
    Provider::MempoolSpace.any_instance.stubs(:get_mempool_txs).returns([])
    OnchainWalletAccount::SecurityResolver.stubs(:resolve).returns(nil)
    OnchainWalletItem.any_instance.stubs(:process_accounts).returns([])

    assert_no_difference -> { OnchainWalletAccount.count } do
      patch update_wallet_onchain_wallet_item_path(item),
            params: { source: "account_modal", chain: "bitcoin", old_wallet_address: old_address, wallet_address: new_address },
            as: :turbo_stream,
            headers: { "Turbo-Frame" => "modal" }
    end

    assert_response :success
    assert_equal new_address, wallet_account.reload.wallet_address
    assert_equal "Wallet address updated.", flash[:notice]
  end

  test "update wallet rejects identical address" do
    item = @family.onchain_wallet_items.create!(name: "On-chain Wallets")
    address = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"
    item.onchain_wallet_accounts.create!(
      chain: "bitcoin",
      wallet_address: address,
      asset_kind: "native",
      symbol: "BTC",
      name: "Bitcoin",
      currency: "USD"
    )

    patch update_wallet_onchain_wallet_item_path(item),
          params: { source: "account_modal", chain: "bitcoin", old_wallet_address: address, wallet_address: address },
          as: :turbo_stream,
          headers: { "Turbo-Frame" => "modal" }

    assert_response :unprocessable_entity
    assert_match "New address is the same", response.body
  end

  test "update ethereum wallet first submit renders token review with existing and new tokens" do
    item = @family.onchain_wallet_items.create!(name: "On-chain Wallets", etherscan_api_key: "key")
    old_address = "0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae"
    new_address = "0x1111111111111111111111111111111111111111"
    usdc_contract = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
    dai_contract = "0x6b175474e89094c44da98b954eedeac495271d0f"

    item.onchain_wallet_accounts.create!(
      chain: "ethereum", wallet_address: old_address, asset_kind: "native",
      symbol: "ETH", name: "Ethereum", currency: "USD"
    )
    item.onchain_wallet_accounts.create!(
      chain: "ethereum", wallet_address: old_address, asset_kind: "erc20",
      token_contract: usdc_contract, symbol: "USDC", name: "USD Coin", currency: "USD"
    )

    Provider::Blockscout.any_instance.stubs(:valid_address?).returns(true)
    Provider::Blockscout.any_instance.stubs(:get_native_balance).returns("1000000000000000000")
    Provider::Blockscout.any_instance.stubs(:get_normal_transactions).returns([])
    Provider::Blockscout.any_instance.stubs(:get_erc20_transfers).returns([
      erc20_transfer(address: new_address, contract: dai_contract, symbol: "DAI", name: "Dai", decimals: "18", value: "5000000000000000000")
    ])
    OnchainWalletAccount::SecurityResolver.stubs(:resolve).returns(nil)

    patch update_wallet_onchain_wallet_item_path(item),
          params: { source: "account_modal", chain: "ethereum", old_wallet_address: old_address, wallet_address: new_address },
          as: :turbo_stream,
          headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_match "Review tokens for new address", response.body
    assert_select "input[name='selected_existing_token_contracts[]'][value='#{usdc_contract}'][checked='checked']"
    assert_select "input[name='selected_token_contracts[]'][value='#{dai_contract}']"
    # Old address still in place until confirmation
    assert OnchainWalletAccount.exists?(wallet_address: old_address)
  end

  test "update ethereum wallet confirmation swaps addresses and removes unchecked existing tokens" do
    item = @family.onchain_wallet_items.create!(name: "On-chain Wallets", etherscan_api_key: "key")
    old_address = "0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae"
    new_address = "0x1111111111111111111111111111111111111111"
    usdc_contract = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
    dai_contract = "0x6b175474e89094c44da98b954eedeac495271d0f"

    item.onchain_wallet_accounts.create!(
      chain: "ethereum", wallet_address: old_address, asset_kind: "native",
      symbol: "ETH", name: "Ethereum", currency: "USD"
    )
    usdc_account = item.onchain_wallet_accounts.create!(
      chain: "ethereum", wallet_address: old_address, asset_kind: "erc20",
      token_contract: usdc_contract, symbol: "USDC", name: "USD Coin", currency: "USD"
    )

    Provider::Blockscout.any_instance.stubs(:valid_address?).returns(true)
    Provider::Blockscout.any_instance.stubs(:get_native_balance).returns("1000000000000000000")
    Provider::Blockscout.any_instance.stubs(:get_normal_transactions).returns([])
    Provider::Blockscout.any_instance.stubs(:get_erc20_transfers).returns([
      erc20_transfer(address: new_address, contract: dai_contract, symbol: "DAI", name: "Dai", decimals: "18", value: "5000000000000000000")
    ])
    OnchainWalletAccount::SecurityResolver.stubs(:resolve).returns(nil)
    OnchainWalletItem.any_instance.stubs(:process_accounts).returns([])

    patch update_wallet_onchain_wallet_item_path(item),
          params: {
            source: "account_modal",
            chain: "ethereum",
            old_wallet_address: old_address,
            wallet_address: new_address,
            reviewed_tokens: "1",
            selected_existing_token_contracts: [],
            selected_token_contracts: [ dai_contract ]
          },
          as: :turbo_stream,
          headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_not OnchainWalletAccount.exists?(usdc_account.id)
    assert_not OnchainWalletAccount.exists?(wallet_address: old_address)
    assert OnchainWalletAccount.exists?(chain: "ethereum", wallet_address: new_address, asset_kind: "native", symbol: "ETH")
    assert OnchainWalletAccount.exists?(chain: "ethereum", wallet_address: new_address, asset_kind: "erc20", token_contract: dai_contract)
  end

  test "destroy wallet disconnects all assets for an address" do
    item = @family.onchain_wallet_items.create!(name: "On-chain Wallets")
    address = "0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae"
    item.onchain_wallet_accounts.create!(
      chain: "ethereum",
      wallet_address: address,
      asset_kind: "native",
      symbol: "ETH",
      name: "Ethereum",
      currency: "USD"
    )
    item.onchain_wallet_accounts.create!(
      chain: "ethereum",
      wallet_address: address,
      asset_kind: "erc20",
      token_contract: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      symbol: "USDC",
      name: "USD Coin",
      currency: "USD"
    )

    assert_difference -> { item.onchain_wallet_accounts.count }, -2 do
      delete wallet_onchain_wallet_item_path(item, chain: "ethereum", wallet_address: address)
    end

    assert_redirected_to accounts_path
    assert_equal "Wallet disconnected.", flash[:notice]
  end

  private
    def erc20_transfer(address:, contract:, symbol:, name:, decimals:, value:)
      {
        "contractAddress" => contract,
        "tokenSymbol" => symbol,
        "tokenName" => name,
        "tokenDecimal" => decimals,
        "value" => value,
        "from" => "0x0000000000000000000000000000000000000000",
        "to" => address,
        "hash" => "#{contract}-hash"
      }
    end
end
