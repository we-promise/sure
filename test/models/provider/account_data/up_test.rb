require "test_helper"
require "ostruct"

class Provider::AccountData::UpTest < ActiveSupport::TestCase
  setup do
    @client = mock("Up transport")
    @adapter = Provider::AccountData::Up.new(client: @client, timezone: "Australia/Sydney")
    @account = Ingestion::Record.account(external_id: "acc_123", name: "Spending", currency: "AUD")
  end

  test "settled normalization preserves the legacy import arguments and enrichment hints" do
    raw = transaction(
      description: "  Coffee Shop  ", message: "Morning coffee", rawText: "COFFEE SHOP SYDNEY",
      category_id: "restaurants-and-cafes", transfer_account_id: "acc_saver",
      foreignAmount: { currencyCode: "USD", value: "-10.00" }
    )
    linked_account = OpenStruct.new(family: OpenStruct.new(timezone: "Australia/Sydney"), currency: "AUD")
    linked_account.define_singleton_method(:enable_category_matcher?) { true }
    legacy_account = OpenStruct.new(current_account: linked_account, currency: "AUD", id: "legacy-account")
    UpItem::LegacyWriter.stubs(:with_account).with(legacy_account).yields(legacy_account)
    categories = mock("current family categories")
    linked_account.family.categories = categories
    categories.expects(:find_by).with(id: "category-id").returns(OpenStruct.new(id: "category-id"))
    merchant = OpenStruct.new(id: "merchant-id", name: "Coffee Shop")
    importer = mock("ledger import adapter")
    category_matcher = mock("category matcher")
    category_matcher.expects(:match).with("restaurants-and-cafes").returns(OpenStruct.new(id: "category-id"))
    Account::ProviderImportAdapter.expects(:new).with(linked_account).returns(importer)
    importer.expects(:find_or_create_merchant).with(
      provider_merchant_id: "up_merchant_#{Digest::MD5.hexdigest('coffee shop')}", name: "Coffee Shop", source: "up"
    ).returns(merchant)
    imported = nil
    importer.expects(:import_transaction).with { |**attributes| imported = attributes }.returns(:entry)

    assert_equal :entry, UpEntry::Processor.new(raw, up_account: legacy_account, category_matcher: category_matcher).process
    normalized = @adapter.normalize_transaction(raw, account: @account)

    %i[external_id name amount currency date].each { |key| assert_equal imported[key], normalized[key] }
    assert_equal "up", imported[:source]
    assert_equal imported[:extra], normalized[:metadata][:extra]
    assert_equal imported[:notes], normalized[:metadata][:notes]
    assert_equal imported[:kind], normalized[:metadata][:kind]
    assert_equal "category-id", imported[:category_id]
    assert_equal "restaurants-and-cafes", normalized[:metadata][:category_slug]
    assert_equal merchant.name, normalized[:metadata][:merchant][:name]
    assert_equal "up_merchant_#{Digest::MD5.hexdigest('coffee shop')}", normalized[:metadata][:merchant][:external_id]
  end

  test "transaction signs and precision never pass through floating point" do
    expense = @adapter.normalize_transaction(transaction(amount: { value: "-0.12345678901234567890", currencyCode: "AUD" }), account: @account)
    income = @adapter.normalize_transaction(transaction(amount: { value: "2500.00", currencyCode: "AUD" }), account: @account)

    assert_equal BigDecimal("0.12345678901234567890"), expense[:amount]
    assert_equal BigDecimal("-2500"), income[:amount]
    assert_instance_of BigDecimal, expense[:amount]
  end

  test "pending IDs remain compatible with both legacy provider IDs and content hashes" do
    [ "pending-up-id", nil ].each do |id|
      raw = transaction(id: id, status: "HELD", settledAt: nil)
      result = @adapter.normalize_transaction(raw, account: @account)

      assert_equal UpEntry::Processor.canonical_external_id(raw), result[:external_id]
      assert result[:pending]
      assert_equal true, result[:metadata][:extra]["up"]["pending"]
      assert_equal Date.new(2026, 1, 15), result[:date]
    end
    raw = transaction(id: "same-up-id", status: "HELD", settledAt: nil)
    pending = @adapter.normalize_transaction(raw, account: @account)
    settled = @adapter.normalize_transaction(raw.merge(status: "SETTLED", settledAt: "2026-01-16T00:00:00+11:00"), account: @account)

    assert_equal pending[:external_id], settled[:external_id]
    assert_equal false, settled[:pending]
    assert_equal false, settled[:metadata][:extra]["up"]["pending"]
  end

  test "dates prefer settlement and use the family's time zone across midnight" do
    raw = transaction(createdAt: "2026-01-14T00:00:00Z", settledAt: "2026-01-14T14:30:00Z")

    assert_equal Date.new(2026, 1, 15), @adapter.normalize_transaction(raw, account: @account)[:date]
    assert_equal Date.new(2026, 1, 14), @adapter.normalize_transaction(raw.merge(status: "HELD", settledAt: nil), account: @account)[:date]
    assert_equal Date.new(2026, 1, 14), @adapter.normalize_transaction(raw.merge(settledAt: "2026-01-14"), account: @account)[:date]
    assert_equal Date.new(2026, 1, 15), @adapter.normalize_transaction(raw.merge(settledAt: Time.iso8601("2026-01-14T14:30:00Z")), account: @account)[:date]
  end

  test "currency normalization and fallback preserve the legacy transaction behavior" do
    assert_equal "USD", @adapter.normalize_transaction(transaction(amount: { value: "-12", currencyCode: " usd " }), account: @account)[:currency]
    [ nil, "", "XXX", "not-currency" ].each do |currency|
      result = @adapter.normalize_transaction(transaction(amount: { value: "-12", currencyCode: currency }), account: @account)
      assert_equal "AUD", result[:currency]
    end
  end

  test "ordinary transactions do not acquire transfer or merchant hints from missing descriptions" do
    result = @adapter.normalize_transaction(transaction(description: nil, message: "", category_id: nil), account: @account)

    assert_nil result[:metadata][:kind]
    assert_nil result[:metadata][:merchant]
    assert_nil result[:metadata][:notes]
    assert_equal I18n.t("transactions.unknown_name"), result[:name]
    refute result[:metadata][:extra]["up"].key?("transfer_account_id")
  end

  test "account normalization preserves signed balances institution and ownership metadata" do
    result = @adapter.normalize_account(account_snapshot(
      accountType: "HOME_LOAN", ownershipType: "JOINT", balance: { value: "-123456.789012345678", currencyCode: " aud " }
    ))

    assert_equal BigDecimal("-123456.789012345678"), result[:balance]
    assert_equal "AUD", result[:currency]
    assert_equal "HOME_LOAN", result[:account_type]
    assert_equal "JOINT", result[:metadata][:ownership_type]
    assert_equal "absolute", result[:metadata].dig(:balance_policy, :debt_transform)
    assert_equal [ "Loan" ], result[:metadata].dig(:balance_policy, :debt_types)
    assert_equal({ name: "Up", domain: "up.com.au" }, result[:metadata][:institution])
    assert_equal BigDecimal("0"), @adapter.normalize_account(account_snapshot(balance: { value: "0", currencyCode: "AUD" }))[:balance]
  end

  test "missing or invalid account values fail instead of becoming zero balances" do
    invalid = [ nil, [], {}, account_snapshot(id: nil), account_snapshot(balance: nil),
      account_snapshot(balance: { value: "bad", currencyCode: "AUD" }),
      account_snapshot(balance: { value: 1.25, currencyCode: "AUD" }),
      account_snapshot(balance: { value: "NaN", currencyCode: "AUD" }),
      account_snapshot(balance: { value: "1", currencyCode: nil }),
      account_snapshot(balance: { value: "1", currencyCode: "XXX" }) ]

    invalid.each do |raw|
      error = assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_account(raw) }
      assert_equal "Invalid Up account", error.message
      assert_nil error.cause
    end
  end

  test "transactions reject missing ownership money status and malformed timestamps" do
    invalid = [ nil, [], transaction(id: {}), transaction(account_id: nil), transaction(account_id: "other-account"),
      transaction(amount: nil), transaction(amount: { value: 1.25, currencyCode: "AUD" }),
      transaction(amount: { value: "Infinity", currencyCode: "AUD" }), transaction(status: nil),
      transaction(status: "UNKNOWN"), transaction(settledAt: nil, createdAt: nil),
      transaction(settledAt: "2026-02-30T12:00:00Z"), transaction(settledAt: "2026-01-15T12:00:00"),
      transaction(settledAt: Float::NAN), transaction(settledAt: "private-invalid-date") ]

    invalid.each do |raw|
      error = assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_transaction(raw, account: @account) }
      refute_includes error.message, "private-invalid-date"
      refute_includes error.message, "other-account"
      assert_nil error.cause
    end
  end

  test "bounded account fetch exposes continuation without declaring a complete inventory" do
    @client.expects(:get_accounts_page).with(cursor: "input-cursor").returns(items: [ account_snapshot ], next_cursor: "next-cursor")

    result = @adapter.list_accounts(cursor: "input-cursor")

    refute result.complete?
    assert_equal "snapshot", result.mode
    assert_equal "next-cursor", result.next_cursor
    assert_equal [ "acc_123" ], result.records.map { |record| record[:external_id] }
  end

  test "transaction fetch forwards the requested window and reports its coverage" do
    from = Date.new(2026, 1, 1)
    through = Date.new(2026, 1, 31)
    @client.expects(:get_account_transactions_page).with(account_id: "acc_123", cursor: nil, since: from, until_date: through)
      .returns(items: [ transaction ], next_cursor: nil)

    result = @adapter.fetch_transactions(account: @account, window: { start: from, end: through })

    assert result.complete?
    assert_equal "snapshot", result.mode
    assert_equal({ "start" => from, "end" => through, "resource" => "transaction" }, result.coverage)
    assert_equal "up_tx_123", result.records.first[:external_id]
  end

  test "complete empty snapshots require an explicit valid response envelope" do
    @client.expects(:get_accounts_page).with(cursor: nil).returns(items: [], next_cursor: nil)

    result = @adapter.list_accounts

    assert result.complete?
    assert_empty result.records
    assert_equal "snapshot", result.mode
  end

  test "malformed pages and transport failures never become successful empty imports" do
    [ nil, {}, { items: [], next_cursor: false }, { items: [], next_cursor: "" }, { items: nil, next_cursor: nil } ].each do |payload|
      @client.expects(:get_accounts_page).with(cursor: nil).returns(payload)
      assert_raises(Provider::AccountData::InvalidResponse) { @adapter.list_accounts }
    end
    @client.expects(:get_accounts_page).with(cursor: nil).raises(Provider::Up::UpError.new("Rate limited", :rate_limited))
    error = assert_raises(Provider::Up::UpError) { @adapter.list_accounts }
    assert_equal :rate_limited, error.error_type
  end

  private
    def transaction(**overrides)
      {
        id: "tx_123", account_id: "acc_123", status: "SETTLED", description: "Coffee Shop",
        amount: { value: "-12.500000000000000001", currencyCode: "AUD" },
        createdAt: "2026-01-15T08:00:00+11:00", settledAt: "2026-01-15T08:30:00+11:00"
      }.merge(overrides)
    end

    def account_snapshot(**overrides)
      {
        id: "acc_123", displayName: "Spending", accountType: "TRANSACTIONAL", ownershipType: "INDIVIDUAL",
        balance: { value: "123.45", currencyCode: "AUD" }
      }.merge(overrides)
    end
end
