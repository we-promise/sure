require "test_helper"

class Provider::AccountData::OnchainWallet::ReadersTest < ActiveSupport::TestCase
  Readers = Provider::AccountData::OnchainWallet::Readers

  test "transport performs one request rejects redirects and parses exact decimals" do
    http = mock("HTTP")
    http.expects(:get).once.with("https://example.test/value", query: {}, follow_redirects: false)
      .returns(stub(code: 200, body: '{"value":0.123456789012345678}'))
    result = Readers::Transport.new(http: http).get("https://example.test/value")
    assert_equal BigDecimal("0.123456789012345678"), result["value"]
    http.expects(:get).once.returns(stub(code: 302, body: "private"))
    assert_raises(Readers::InvalidResponse) { Readers::Transport.new(http: http).get("https://example.test/value") }
  end

  test "throttling authentication and network failures return without retry or private error text" do
    http = mock("HTTP")
    [ [ 429, Readers::RateLimited ], [ 403, Readers::AuthenticationError ] ].each do |code, klass|
      http.expects(:get).once.returns(stub(code: code, body: "private-key"))
      error = assert_raises(klass) { Readers::Transport.new(http: http).get("https://example.test/value") }
      assert_not_includes error.message, "private-key"
    end
    http.expects(:get).once.raises(Net::ReadTimeout, "private-key")
    error = assert_raises(Readers::Error) { Readers::Transport.new(http: http).get("https://example.test/value") }
    assert_nil error.cause
    assert_not_includes error.message, "private-key"
  end

  test "configured endpoints reject credentials fragments and unsupported protocols" do
    %w[file:///private https://user:password@example.test https://example.test/#fragment].each do |url|
      assert_raises(ArgumentError) { Readers::Transport.endpoint(url) }
    end
    assert_equal "http://localhost:9000/api", Readers::Transport.endpoint("http://localhost:9000/api/")
  end

  test "only explicit Binance invalid-symbol response is retained as unavailable pricing" do
    http = mock("market HTTP")
    reader = Readers::Transport.new(http: http)
    http.expects(:get).once.returns(stub(code: 400, body: '{"code":-1121,"msg":"Invalid symbol."}'))
    assert_equal(-1121, reader.get("https://example.test/klines", invalid_binance_symbol: true)["code"])
    http.expects(:get).once.returns(stub(code: 400, body: '{"code":-1121}'))
    assert_raises(Readers::InvalidResponse) { reader.get("https://example.test/klines") }
    http.expects(:get).once.returns(stub(code: 400, body: '{"code":-1100}'))
    assert_raises(Readers::InvalidResponse) { reader.get("https://example.test/klines", invalid_binance_symbol: true) }
  end

  test "Bitcoin summary and history are independent physical reads with explicit after cursor" do
    transport = mock("Bitcoin transport")
    reader = Readers::Bitcoin.new(base_url: "https://example.test/api", transport: transport)
    address = "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"
    data = { "chain_stats" => {}, "mempool_stats" => {} }
    transport.expects(:get).once.with("https://example.test/api/address/#{address}").returns(data)
    assert_equal data, reader.summary(address: address)
    txid = "a" * 64
    transport.expects(:get).once.with("https://example.test/api/address/#{address}/txs/chain/#{txid}").returns([ { "txid" => "b" * 64 } ])
    assert_equal 1, reader.transactions(address: address, after: txid).size
    assert_raises(ArgumentError) { reader.transactions(address: address, after: "https://other/path") }
    assert_raises(ArgumentError) { reader.summary(address: "bad") }
  end

  test "Bitcoin malformed responses do not turn into empty balances or history" do
    transport = mock("Bitcoin transport")
    reader = Readers::Bitcoin.new(base_url: "https://example.test", transport: transport)
    address = "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"
    transport.expects(:get).returns({})
    assert_raises(Readers::InvalidResponse) { reader.summary(address: address) }
    transport.expects(:get).returns({})
    assert_raises(Readers::InvalidResponse) { reader.transactions(address: address) }
  end

  test "EVM token inventory stays unfiltered while transfer pages retain fixed ERC20 filter" do
    transport = mock("EVM transport")
    reader = Readers::Evm.new(base_url: "https://example.test", transport: transport)
    address = "0x#{'a' * 40}"
    transport.expects(:get).once.with("https://example.test/api/v2/addresses/#{address}/token-balances", query: {}).returns([])
    assert_nil reader.page(resource: :token_balances, address: address)[:next_cursor]
    data = { "items" => [ { "value" => "1" } ], "next_page_params" => { "block_number" => 2, "index" => 3 } }
    transport.expects(:get).once.with("https://example.test/api/v2/addresses/#{address}/token-transfers", query: { "type" => "ERC-20" }).returns(data)
    first = reader.page(resource: :token_transfers, address: address)
    assert_equal data["next_page_params"], first[:next_cursor]
    transport.expects(:get).once.with("https://example.test/api/v2/addresses/#{address}/token-transfers", query: { "type" => "ERC-20", "block_number" => 2, "index" => 3 })
      .returns({ "items" => [], "next_page_params" => nil })
    assert_nil reader.page(resource: :token_transfers, address: address, cursor: first[:next_cursor])[:next_cursor]
  end

  test "EVM empty continuations malformed collections and cursor filter overrides fail" do
    transport = mock("EVM transport")
    reader = Readers::Evm.new(base_url: "https://example.test", transport: transport)
    address = "0x#{'a' * 40}"
    [ [], {}, { "items" => [], "next_page_params" => { "index" => 1 } } ].each do |value|
      transport.expects(:get).once.returns(value)
      assert_raises(Readers::InvalidResponse) { reader.page(resource: :native_transfers, address: address) }
    end
    assert_raises(ArgumentError) { reader.page(resource: :token_transfers, address: address, cursor: { "type" => "ERC-721" }) }
    assert_raises(ArgumentError) { reader.page(resource: :native_transfers, address: address, cursor: { "url" => [ "https://other" ] }) }
  end

  test "Etherscan history has a fixed block window and no inventory authority" do
    transport = mock("Etherscan transport")
    reader = Readers::Etherscan.new(api_key: "private-key", chain_id: "1", transport: transport)
    address = "0x#{'a' * 40}"
    transport.expects(:get).once.with("https://api.etherscan.io/v2/api", query: { apikey: "private-key", chainid: "1", module: "account",
      action: "tokentx", address: address, startblock: 5, endblock: 20, page: 2, offset: 1000, sort: "asc" })
      .returns({ "status" => "1", "result" => [ { "hash" => "tx" } ] })
    result = reader.page(resource: :token_transfers, address: address, page: 2, start_block: 5, end_block: 20)
    assert result[:complete]
    assert_equal "tx", result[:rows].sole["hash"]
    assert_raises(ArgumentError) { reader.page(resource: :token_balances, address: address, page: 1, start_block: 0, end_block: 20) }
    assert_not_includes reader.inspect, "private-key"
  end

  test "Etherscan rate limits malformed results and explicit no-history responses remain distinct" do
    transport = mock("Etherscan transport")
    reader = Readers::Etherscan.new(api_key: "private-key", chain_id: "1", transport: transport)
    arguments = { resource: :native_transfers, address: "0x#{'a' * 40}", page: 1, start_block: 0, end_block: 20 }
    transport.expects(:get).once.returns({ "status" => "0", "message" => "No transactions found", "result" => [] })
    assert_empty reader.page(**arguments)[:rows]
    transport.expects(:get).once.returns({ "status" => "0", "message" => "NOTOK", "result" => "Max rate limit private-key" })
    error = assert_raises(Readers::RateLimited) { reader.page(**arguments) }
    assert_not_includes error.message, "private-key"
    transport.expects(:get).once.returns({ "status" => "1", "result" => {} })
    assert_raises(Readers::InvalidResponse) { reader.page(**arguments) }
  end

  test "Solana token programs are independent requests and signatures retain their cursor" do
    transport = mock("RPC transport")
    reader = Readers::Solana.new(url: "https://example.test", transport: transport)
    address = "A" * 44
    program = Provider::SolanaRpc::TOKEN_PROGRAM_IDS.first
    transport.expects(:post).once.with("https://example.test", payload: { jsonrpc: "2.0", id: 1, method: "getTokenAccountsByOwner",
      params: [ address, { programId: program }, { encoding: "jsonParsed" } ] }).returns(rpc({ "value" => [] }))
    assert_equal [], reader.token_accounts(address: address, program_id: program)["value"]
    before = "b" * 88
    transport.expects(:post).once.with("https://example.test", payload: { jsonrpc: "2.0", id: 1, method: "getSignaturesForAddress",
      params: [ address, { limit: 25, before: before } ] }).returns(rpc([]))
    assert_empty reader.signatures(address: address, before: before)
  end

  test "Solana missing transaction remains unknown and malformed RPC does not become zero" do
    transport = mock("RPC transport")
    reader = Readers::Solana.new(url: "https://example.test", transport: transport)
    transport.expects(:post).once.returns(rpc(nil))
    assert_nil reader.transaction(signature: "b" * 88)
    [ rpc(nil), rpc({ "value" => "0" }), { "jsonrpc" => "2.0", "id" => 2, "result" => { "value" => 0 } } ].each do |body|
      transport.expects(:post).once.returns(body)
      assert_raises(Readers::InvalidResponse) { reader.balance(address: "A" * 44) }
    end
    assert_raises(ArgumentError) { reader.token_accounts(address: "A" * 44, program_id: "untrusted-program") }
  end

  private
    def rpc(result)
      { "jsonrpc" => "2.0", "id" => 1, "result" => result }
    end
end
