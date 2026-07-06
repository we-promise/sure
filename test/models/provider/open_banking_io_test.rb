require "test_helper"
require "open_banking_io"

class Provider::OpenBankingIoTest < ActiveSupport::TestCase
  setup do
    @fake_client = mock("open_banking_io_client")
    OpenBankingIO::Client.stubs(:new).returns(@fake_client)
    @provider = Provider::OpenBankingIo.new(
      api_base_url: "https://api.example.com",
      api_key: "test-api-key",
      private_key: "test-private-key"
    )
  end

  test "get_accounts maps struct value objects into hashes with string amounts" do
    account = OpenBankingIO::Account.new(
      id: "acc_1",
      aspsp_name: "Test Bank",
      aspsp_country: "DE",
      currency: "EUR",
      account_type: "CACC",
      bic: "TESTDEFF",
      needs_reconnect: false,
      iban: "DE00 0000",
      bban: nil,
      owner_name: "Jane Doe",
      account_name: "Everyday",
      product: "Current",
      display_name: "Everyday Account",
      balances: [
        OpenBankingIO::Balance.new(type: "ITBD", name: "Booked", amount: BigDecimal("1234.56"), currency: "EUR", reference_date: "2026-01-15")
      ]
    )
    @fake_client.expects(:get_accounts).returns([ account ])

    result = @provider.get_accounts

    assert_equal 1, result.size
    mapped = result.first
    assert_equal "acc_1", mapped[:id]
    assert_equal "CACC", mapped[:account_type]
    assert_equal "1234.56", mapped[:balances].first[:amount]
    assert_kind_of String, mapped[:balances].first[:amount]
  end

  test "get_account_transactions paginates and maps transactions" do
    page1_items = Array.new(Provider::OpenBankingIo::PAGE_LIMIT) do |i|
      OpenBankingIO::Transaction.new(id: "tx_#{i}", currency: "EUR", credit_debit_indicator: "DBIT", status: "BOOK", amount: BigDecimal("1.00"))
    end
    page2_items = [
      OpenBankingIO::Transaction.new(id: "tx_last", currency: "EUR", credit_debit_indicator: "CRDT", status: "BOOK", amount: BigDecimal("2.50"))
    ]

    total = Provider::OpenBankingIo::PAGE_LIMIT + 1

    seq = sequence("pages")
    @fake_client.expects(:get_transactions)
      .with("acc_1", from: "2026-01-01", to: nil, limit: Provider::OpenBankingIo::PAGE_LIMIT, offset: 0)
      .in_sequence(seq)
      .returns(OpenBankingIO::TransactionPage.new(items: page1_items, total: total))
    @fake_client.expects(:get_transactions)
      .with("acc_1", from: "2026-01-01", to: nil, limit: Provider::OpenBankingIo::PAGE_LIMIT, offset: Provider::OpenBankingIo::PAGE_LIMIT)
      .in_sequence(seq)
      .returns(OpenBankingIO::TransactionPage.new(items: page2_items, total: total))

    result = @provider.get_account_transactions(account_id: "acc_1", start_date: Date.new(2026, 1, 1))

    assert_equal total, result.size
    assert_equal "tx_last", result.last[:id]
    assert_equal "2.5", result.last[:amount]
  end

  test "wraps HTTP 401 into unauthorized provider error" do
    @fake_client.expects(:get_accounts).raises(OpenBankingIO::HTTPError.new(401, "unauthorized"))

    error = assert_raises(Provider::OpenBankingIo::Error) do
      @provider.get_accounts
    end

    assert_equal :unauthorized, error.error_type
  end

  test "wraps HTTP 429 into rate_limited provider error" do
    @fake_client.expects(:get_accounts).raises(OpenBankingIO::HTTPError.new(429, "slow down"))

    error = assert_raises(Provider::OpenBankingIo::Error) do
      @provider.get_accounts
    end

    assert_equal :rate_limited, error.error_type
  end
end
