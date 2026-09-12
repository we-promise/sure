require "test_helper"

class Provider::BibitTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Bibit.new
    @provider.stubs(:throttle_request)
  end

  # ================================
  #          Health Check
  # ================================

  test "healthy? returns true when RD66 is reachable" do
    stub_successful_product_response("RD66", { "symbol" => "RD66", "name" => "Avrist Ada Kas Mutiara" })

    assert @provider.healthy?
  end

  # ================================
  #        Search Securities
  # ================================

  test "search_securities returns fund results" do
    stub_successful_list_response([
      { "symbol" => "RD780", "name" => "Investa Dana Dollar Mandiri", "type" => "Obligasi", "nav" => { "value" => 1.479 } },
      { "symbol" => "RD3734", "name" => "Dana Investasi Infrastruktur Toll Road Mandiri", "type" => "Dana Investasi Real Estate", "nav" => { "value" => 1505.53 } }
    ])

    result = @provider.search_securities("mandiri")
    assert result.success?

    securities = result.data
    assert_equal 2, securities.length

    first = securities.first
    assert_equal "RD780", first.symbol
    assert_equal "Investa Dana Dollar Mandiri", first.name
    assert_equal "XIDX", first.exchange_operating_mic
    assert_equal "ID", first.country_code
    assert_equal "IDR", first.currency
  end

  # ================================
  #       Fetch Security Info
  # ================================

  test "fetch_security_info returns fund details" do
    stub_successful_product_response("RD66", {
      "symbol" => "RD66",
      "name" => "Avrist Ada Kas Mutiara",
      "type" => "Pasar Uang",
      "investment_manager" => { "name" => "Avrist Asset Management, PT" },
      "custodian_bank" => { "name" => "Standard Chartered Bank" }
    })

    result = @provider.fetch_security_info(symbol: "RD66", exchange_operating_mic: "XIDX")
    assert result.success?

    info = result.data
    assert_equal "RD66", info.symbol
    assert_equal "Avrist Ada Kas Mutiara", info.name
    assert_equal "mutual fund", info.kind
    assert_equal "XIDX", info.exchange_operating_mic
    assert_includes info.description, "Avrist Asset Management"
  end

  # ================================
  #      Fetch Security Prices
  # ================================

  test "fetch_security_prices returns NAV history" do
    stub_successful_chart_response("RD66", [
      { "date" => 1783616400, "formated_date" => "2026-07-10", "value" => 1582.20 },
      { "date" => 1783875600, "formated_date" => "2026-07-13", "value" => 1582.93 },
      { "date" => 1783962000, "formated_date" => "2026-07-14", "value" => 1583.10 }
    ])

    result = @provider.fetch_security_prices(
      symbol: "RD66",
      start_date: Date.new(2026, 7, 10),
      end_date: Date.new(2026, 7, 14)
    )
    assert result.success?

    prices = result.data
    assert_equal 3, prices.length
    assert_equal Date.new(2026, 7, 10), prices.first.date
    assert_equal 1582.20, prices.first.price
    assert_equal "IDR", prices.first.currency
    assert_equal "RD66", prices.first.symbol
  end

  test "fetch_security_prices filters by date range" do
    stub_successful_chart_response("RD66", [
      { "date" => 1783616400, "formated_date" => "2026-07-10", "value" => 1582.20 },
      { "date" => 1783875600, "formated_date" => "2026-07-13", "value" => 1582.93 },
      { "date" => 1783962000, "formated_date" => "2026-07-14", "value" => 1583.10 }
    ])

    result = @provider.fetch_security_prices(
      symbol: "RD66",
      start_date: Date.new(2026, 7, 13),
      end_date: Date.new(2026, 7, 14)
    )
    assert result.success?

    prices = result.data
    assert_equal 2, prices.length
    assert_equal Date.new(2026, 7, 13), prices.first.date
  end

  test "fetch_security_prices skips entries with nil or zero NAV" do
    stub_successful_chart_response("RD66", [
      { "date" => 1783616400, "formated_date" => "2026-07-10", "value" => 1582.20 },
      { "date" => 1783875600, "formated_date" => "2026-07-13", "value" => nil },
      { "date" => 1783962000, "formated_date" => "2026-07-14", "value" => 0 }
    ])

    result = @provider.fetch_security_prices(
      symbol: "RD66",
      start_date: Date.new(2026, 7, 10),
      end_date: Date.new(2026, 7, 14)
    )
    assert result.success?
    assert_equal 1, result.data.length
  end

  # ================================
  #      Fetch Security Price
  # ================================

  test "fetch_security_price returns closest price on or before date" do
    stub_successful_chart_response("RD66", [
      { "date" => 1783616400, "formated_date" => "2026-07-10", "value" => 1582.20 },
      { "date" => 1783875600, "formated_date" => "2026-07-13", "value" => 1582.93 }
    ])

    result = @provider.fetch_security_price(
      symbol: "RD66",
      date: Date.new(2026, 7, 12) # Weekend — no trading, should get 2026-07-10
    )
    assert result.success?
    assert_equal Date.new(2026, 7, 10), result.data.date
    assert_equal 1582.20, result.data.price
  end

  # ================================
  #          Decryption
  # ================================

  test "decrypt handles valid AES-CBC encrypted data" do
    # Build a known encrypted payload
    plaintext = '{"symbol":"RD66","name":"Test Fund"}'
    iv = OpenSSL::Random.random_bytes(16)
    key = "a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6" # 32 UTF-8 chars

    cipher = OpenSSL::Cipher::AES.new(256, :CBC)
    cipher.encrypt
    cipher.iv = iv
    cipher.key = key

    ciphertext = cipher.update(plaintext) + cipher.final

    encrypted = iv.unpack1("H*") + ciphertext.unpack1("H*") + key

    result = @provider.send(:decrypt, encrypted)
    assert_equal "RD66", result["symbol"]
    assert_equal "Test Fund", result["name"]
  end

  # ================================
  #         Period Selection
  # ================================

  test "select_period measures from start_date to today, not just the requested span" do
    travel_to Date.new(2026, 8, 11) do
      # Recent ranges — trailing window from today
      assert_equal "1w", @provider.send(:select_period, Date.new(2026, 8, 6), Date.new(2026, 8, 11))
      assert_equal "1m", @provider.send(:select_period, Date.new(2026, 7, 20), Date.new(2026, 8, 11))
      assert_equal "3m", @provider.send(:select_period, Date.new(2026, 6, 1), Date.new(2026, 8, 11))
      assert_equal "1y", @provider.send(:select_period, Date.new(2026, 1, 1), Date.new(2026, 8, 11))
      assert_equal "all", @provider.send(:select_period, Date.new(2020, 1, 1), Date.new(2026, 8, 11))
    end
  end

  test "select_period picks a wider window for historical ranges far from today" do
    travel_to Date.new(2026, 8, 11) do
      # July 10-14 is a 4-day span, but 32 days ago — must pick "3m" not "1w"
      assert_equal "3m", @provider.send(:select_period, Date.new(2026, 7, 10), Date.new(2026, 7, 14))
    end
  end

  private

    def encrypt_payload(data)
      plaintext = data.to_json
      iv = OpenSSL::Random.random_bytes(16)
      key = "x1y2z3a4b5c6d7e8f9g0h1i2j3k4l5m6" # 32 UTF-8 chars

      cipher = OpenSSL::Cipher::AES.new(256, :CBC)
      cipher.encrypt
      cipher.iv = iv
      cipher.key = key

      ciphertext = cipher.update(plaintext) + cipher.final

      iv.unpack1("H*") + ciphertext.unpack1("H*") + key
    end

    def stub_bibit_response(path, data, status: 200)
      encrypted = encrypt_payload(data)
      body = { "message" => "Success", "data" => encrypted }.to_json

      stub = stub_request(:get, /api\.bibit\.id#{Regexp.escape(path)}/)
        .to_return(status: status, body: body, headers: { "Content-Type" => "application/json" })
      stub
    end

    def stub_successful_product_response(symbol, data)
      stub_bibit_response("/products/#{symbol}", data)
    end

    def stub_successful_list_response(data)
      stub_bibit_response("/products/list", data)
    end

    def stub_successful_chart_response(symbol, chart_data)
      stub_bibit_response("/products/#{symbol}/chart", { "chart" => chart_data })
    end
end
