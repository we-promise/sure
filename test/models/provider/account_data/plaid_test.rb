require "test_helper"

class Provider::AccountData::PlaidTest < ActiveSupport::TestCase
  setup do
    @client = mock("Plaid exact reader")
    @adapter = adapter
    @account = @adapter.normalize_account(account_row, products: %w[transactions investments liabilities])
    @investment = @adapter.normalize_account(account_row(account_id: "investment", type: "investment", subtype: "brokerage"), products: %w[investments])
  end

  test "regional application credentials must match the pinned connection realm" do
    context = { region: "eu", environment: "sandbox", timezone: "UTC", observed_at: Time.utc(2026, 9, 14),
      application_credentials: { region: "us", environment: "sandbox", client_id: "app-id", secret: "app-secret" },
      plaid_deployment_binding: nil,
      connection_details: { external_id: "item-1" }, pending_override: false, pending_preference: true }
    assert_raises(ArgumentError) { @adapter.class.build(credentials: { access_token: "item-token" }, settings: {}, context: context) }
    context[:application_credentials][:region] = "eu"
    built = @adapter.class.build(credentials: { access_token: "item-token" }, settings: {}, context: context)
    assert_equal [ "transactions" ], built.capabilities
    refute @adapter.class.native_ready?
    assert_includes @adapter.class.context_sources, :application_credentials
    assert_raises(Provider::AccountData::UnsupportedCapability) { built.fetch_transactions(account: @account) }
  end

  test "inventory captures product and institution evidence and preserves account type enrichment hints" do
    item = { item: { item_id: "item-1", institution_id: "ins-1", available_products: [ "transactions" ], billed_products: [ "liabilities" ] } }
    institution = { institution: { institution_id: "ins-1", name: "Bank", url: "https://bank.test", private_field: "private-data" } }
    @client.expects(:get_item).returns(item)
    @client.expects(:get_accounts).returns(item_response(accounts: [ account_row(mask: "1234") ]))
    @client.expects(:get_institution).with(institution_id: "ins-1").returns(institution)
    page = @adapter.list_accounts
    record = page.records.sole
    assert_equal %w[transactions liabilities], record[:metadata][:products]
    assert_equal "Depository", record[:metadata][:account_enrichment][:accountable_type]
    assert_equal "checking", record[:metadata][:account_enrichment][:subtype]
    assert_equal "1234", record[:sensitive_details][:mask]
    assert_equal institution, page.evidence["institution"]
    refute_includes record[:metadata].to_s, "private-data"
  end

  test "inventory from a different item cannot overwrite connection identity" do
    @client.expects(:get_item).returns(item: { item_id: "other-item", available_products: [], billed_products: [] })
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.list_accounts }
  end

  test "transactions preserve provider IDs pending linkage merchant details and native signs" do
    raw = transaction(pending_transaction_id: "pending-old", merchant_name: "Merchant", merchant_entity_id: "merchant-1",
      website: "https://merchant.test", logo_url: "https://merchant.test/logo", amount: "-12.34567890123456789")
    record = @adapter.normalize_transaction(raw, account: @account)
    assert_equal "transaction-1", record[:external_id]
    assert_equal "pending-old", record[:pending_external_id]
    assert_equal "pending-old", record[:metadata][:extra][:plaid][:pending_transaction_id]
    assert_equal false, record[:metadata][:extra][:plaid][:pending]
    assert_equal BigDecimal("-12.34567890123456789"), record[:amount]
    assert_equal "https://merchant.test", record[:metadata][:merchant][:website_url]
    assert_equal "merchant-1", record[:metadata][:merchant][:external_id]
  end

  test "category candidates preserve detailed and parent matching precedence" do
    record = @adapter.normalize_transaction(transaction(personal_finance_category: { detailed: "INCOME_WAGES" }))
    hints = record[:metadata][:category_candidates]
    assert_equal [ "income_wages" ], hints[:exact_names]
    assert_includes hints[:aliases], "salary"
    assert_includes hints[:fallback_aliases], "income"
    assert_equal "legacy_ascii", hints[:normalization]
  end

  test "native invalid monetary pending and ownership values cannot reach the ledger" do
    [ transaction(amount: 0.1), transaction(amount: "bad"), transaction(pending: nil), transaction(account_id: "foreign") ].each do |raw|
      assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_transaction(raw, account: @account) }
    end
    record = @adapter.normalize_legacy_transaction(transaction(amount: 0.1), account: @account)
    assert_equal BigDecimal("0.1"), record[:amount]
  end

  test "grouped updates retain unlinked account observations modified-before-added order and unresolved removals" do
    raw = group_response(modified: [ transaction(transaction_id: "modified") ], added: [ transaction(transaction_id: "added"), transaction(account_id: "unlinked", transaction_id: "unlinked-tx") ],
      removed: [ { account_id: "account-1", transaction_id: "removed" }, { transaction_id: "unassigned" } ])
    @client.expects(:get_transactions_page).with(cursor: "committed").returns(raw)
    group = @adapter.fetch_transaction_group(start_cursor: "committed", generation_id: "generation-1")
    assert_instance_of Provider::AccountData::TransactionGroup, group
    assert group.complete?
    assert_equal %w[modified added], group.account_pages["account-1"].records.map { |record| record[:external_id] }
    assert_equal %w[modified added], group.account_pages["account-1"].records.map { |record| record[:metadata][:change_type] }
    assert_equal [ "removed" ], group.account_pages["account-1"].removed_ids
    assert_equal [ "unassigned" ], group.unassigned_removed_ids
    assert_equal "unlinked-tx", group.account_pages["unlinked"].records.sole[:external_id]
    assert group.account_pages.values.none?(&:complete?)
    assert_equal raw, group.evidence["response"]
  end

  test "pending preference filters financial output while preserving raw evidence and posted linking IDs" do
    selected = adapter(include_pending: false)
    raw = group_response(added: [ transaction(pending: true), transaction(transaction_id: "posted", pending_transaction_id: "transaction-1") ])
    @client.expects(:get_transactions_page).returns(raw)
    group = selected.fetch_transaction_group(start_cursor: nil, generation_id: "generation-1")
    page = group.account_pages["account-1"]
    assert_equal [ "posted" ], page.records.map { |record| record[:external_id] }
    assert_equal "transaction-1", page.records.sole[:pending_external_id]
    assert_equal 1, page.warnings.sole["count"]
    assert_equal 2, group.evidence["response"][:added].size
  end

  test "mutation and continuation transport errors require a whole generation restart" do
    %w[TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION API_ERROR].each do |code|
      @client.expects(:get_transactions_page).with(cursor: "provisional-page").raises(Provider::Plaid::IngestionClient::Error.new(code))
      error = assert_raises(Provider::AccountData::Plaid::PaginationRestartRequired) do
        @adapter.fetch_transaction_group(start_cursor: "committed", cursor: "provisional-page", generation_id: "generation-1")
      end
      assert_equal "committed", error.start_cursor
      assert_equal "generation-1", error.generation_id
      refute_includes error.message, "provisional-page"
      assert_nil error.cause
    end
  end

  test "an initial nonpagination authentication error keeps its original stable error code" do
    @client.expects(:get_transactions_page).raises(Provider::Plaid::IngestionClient::Error.new("ITEM_LOGIN_REQUIRED"))
    error = assert_raises(Provider::Plaid::IngestionClient::Error) { @adapter.fetch_transaction_group(start_cursor: nil, generation_id: "generation-1") }
    assert_equal "ITEM_LOGIN_REQUIRED", error.error_code
  end

  test "investment balance subtracts real holdings but excludes only legacy brokerage USD cash" do
    @client.expects(:get_accounts).returns(item_response(accounts: [ account_row(account_id: "investment", type: "investment", subtype: "brokerage", balances: { current: "1000", available: "150", iso_currency_code: "USD" }) ]))
    @client.expects(:get_holdings).with(account_id: "investment").returns(item_response(accounts: [], holdings: [ holding(quantity: "3", institution_price: "200"), holding(security_id: "cash", quantity: "100", institution_price: "1") ],
      securities: [ security, security(security_id: "cash", ticker_symbol: "CUR:USD") ]))
    page = @adapter.fetch_balance(account: @investment)
    assert_equal BigDecimal("1000"), page.records.sole[:balance]
    assert_equal BigDecimal("400"), page.records.sole[:cash_balance]
    assert page.evidence.key?("holdings")
  end

  test "cash-equivalent money market securities still count as holdings" do
    @client.expects(:get_accounts).returns(item_response(accounts: [ account_row(account_id: "investment", type: "investment", subtype: "brokerage") ]))
    @client.expects(:get_holdings).returns(item_response(accounts: [], holdings: [ holding(quantity: "3", institution_price: "200") ], securities: [ security(type: "cash", is_cash_equivalent: true) ]))
    page = @adapter.fetch_balance(account: @investment)
    assert_equal BigDecimal("-500"), page.records.sole[:cash_balance]
    assert_equal "negative_investment_cash", page.warnings.sole["code"]
  end

  test "holding financial identity stays security date currency while observation IDs remain stable" do
    record = @adapter.normalize_holding(holding, account: @investment, securities: [ security ])
    assert_equal "plaid_holding:investment:security-1:2026-09-12:USD", record[:external_id]
    assert_equal "security_date_currency", record[:metadata][:holding_identity]
    assert_equal false, record[:metadata][:delete_future_holdings]
    assert_equal BigDecimal("24.69135780246913578"), record[:amount]
    assert_equal "XNAS", record[:security][:exchange_operating_mic]
  end

  test "security lookup preserves proxy mapping and suppresses brokerage pseudo-holdings" do
    proxy = security(security_id: "proxy", proxy_security_id: "security-1", ticker_symbol: "PROXY")
    assert_equal "PROXY", @adapter.normalize_holding(holding, account: @investment, securities: [ proxy ])[:security][:ticker]
    assert_nil @adapter.normalize_holding(holding, account: @investment, securities: [ security(ticker_symbol: "CUR:USD") ])
    assert_nil @adapter.normalize_holding(holding, account: @investment, securities: [])
  end

  test "investment sell signage follows amount and type despite positive upstream quantity" do
    record = @adapter.normalize_activity(activity(type: "sell", quantity: "2", amount: "-30", price: "12"), account: @investment, securities: [ security ])
    assert_equal "investment-tx", record[:external_id]
    assert_equal "trade", record[:ledger_type]
    assert_equal BigDecimal("-2"), record[:quantity]
    assert_equal BigDecimal("-24"), record[:amount]
    assert_equal "Sell", record[:metadata][:investment_activity_label]
  end

  test "Plaid dividend and interest preserve the legacy zero-quantity Trade representation" do
    %w[dividend interest].each do |type|
      record = @adapter.normalize_activity(activity(type: type, quantity: "0", amount: "100", price: "1"), account: @investment, securities: [ security ])
      assert_equal "trade", record[:ledger_type]
      assert_equal BigDecimal("0"), record[:quantity]
      assert_equal BigDecimal("0"), record[:amount]
      assert_equal true, record[:metadata][:allow_zero_quantity]
      assert_equal type.capitalize, record[:metadata][:investment_activity_label]
    end
  end

  test "reported negative amount overrides a buy type for quantity without rewriting its legacy label" do
    record = @adapter.normalize_activity(activity(type: "buy", quantity: "2", amount: "-20", price: "10"), account: @investment, securities: [ security ])
    assert_equal "sell", record[:activity_type]
    assert_equal BigDecimal("-2"), record[:quantity]
    assert_equal "Buy", record[:metadata][:investment_activity_label]
  end

  test "investment cash types retain raw amounts and do not require a security" do
    %w[cash fee transfer contribution withdrawal].each do |type|
      record = @adapter.normalize_activity(activity(type: type, amount: "-20", security_id: nil), account: @investment, securities: [])
      assert_equal "transaction", record[:ledger_type]
      assert_equal BigDecimal("-20"), record[:amount]
      refute record.attributes.key?(:security)
    end
  end

  test "legacy investment Floats convert only through explicit entrypoints" do
    raw = activity(quantity: 2.0, amount: 20.0, price: 0.1)
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_activity(raw, account: @investment, securities: [ security ]) }
    record = @adapter.normalize_legacy_activity(raw, account: @investment, securities: [ security ])
    assert_equal BigDecimal("0.2"), record[:amount]
  end

  test "investment pagination preserves date bounds and rejects shifting advertised totals" do
    @client.expects(:get_investment_transactions_page).with(start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 9, 14), offset: 0, account_id: "investment")
      .returns(item_response(accounts: [], securities: [ security ], investment_transactions: [ activity ], total_investment_transactions: 2))
    first = @adapter.fetch_activities(account: @investment, window: { explicit_start: true, start: "2026-01-01", end: "2026-09-14" })
    refute first.complete?
    @client.expects(:get_investment_transactions_page).with(start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 9, 14), offset: 1, account_id: "investment")
      .returns(item_response(accounts: [], securities: [ security ], investment_transactions: [ activity(investment_transaction_id: "next") ], total_investment_transactions: 3))
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.fetch_activities(account: @investment, cursor: first.next_cursor) }
  end

  test "liability enrichment preserves credit APR ordering and the legacy nonnil direct-update strategy" do
    account = @adapter.normalize_account(account_row(type: "credit", subtype: "credit card"))
    values = @adapter.normalize_liabilities({ liabilities: { credit: [ { account_id: "account-1", minimum_payment_amount: "25.25", aprs: [ { apr_percentage: "12.9" }, { apr_percentage: "99" } ] } ] } }, account: account)
    assert_equal "update_non_null", values["strategy"]
    assert_equal "CreditCard", values["accountable_type"]
    assert_equal BigDecimal("25.25"), values["attributes"]["minimum_payment"]
    assert_equal BigDecimal("12.9"), values["attributes"]["apr"]
  end

  test "mortgage and student mappings preserve rates origination balance and legacy term arithmetic" do
    mortgage = @adapter.normalize_account(account_row(type: "loan", subtype: "mortgage"))
    values = @adapter.normalize_liabilities({ liabilities: { mortgage: [ { account_id: "account-1", interest_rate: { type: "variable", percentage: "5.25" } } ] } }, account: mortgage)
    assert_equal "variable", values["attributes"]["rate_type"]
    assert_equal "update", values["strategy"]
    student = @adapter.normalize_account(account_row(type: "loan", subtype: "student"))
    values = @adapter.normalize_liabilities({ liabilities: { student: [ { account_id: "account-1", interest_rate_percentage: "4.75", origination_principal_amount: "12345.67",
      origination_date: "2020-01-01", expected_payoff_date: "2030-01-01" } ] } }, account: student)
    assert_equal "fixed", values["attributes"]["rate_type"]
    assert_equal BigDecimal("12345.67"), values["attributes"]["initial_balance"]
    assert_equal 121, values["attributes"]["term_months"]
  end

  test "liability responses cannot mutate another linked account" do
    account = @adapter.normalize_account(account_row(type: "credit", subtype: "credit card"))
    assert_raises(Provider::AccountData::InvalidResponse) do
      @adapter.normalize_liabilities({ liabilities: { credit: [ { account_id: "foreign", minimum_payment_amount: "25" } ] } }, account: account)
    end
  end

  test "liability HTTP failure keeps the freshly read balance without replaying stale liability metadata" do
    credit = @adapter.normalize_account(account_row(type: "credit", subtype: "credit card"), products: %w[liabilities])
    credit = Ingestion::Record.account(**credit.attributes.merge(metadata: credit[:metadata].merge(accountable_attributes: {
      accountable_type: "CreditCard", strategy: "update_non_null", attributes: { apr: BigDecimal("99") }
    })))
    @client.expects(:get_accounts).returns(item_response(accounts: [ account_row(type: "credit", subtype: "credit card") ]))
    @client.expects(:get_liabilities).with(account_id: "account-1").raises(Provider::Plaid::IngestionClient::Error.new("PRODUCT_NOT_READY"))
    page = @adapter.fetch_balance(account: credit)
    assert_not page.complete?
    assert_equal BigDecimal("100"), page.records.sole[:balance]
    assert_equal BigDecimal("100"), page.records.sole[:cash_balance]
    assert_equal "CreditCard", page.records.sole[:metadata][:account_enrichment][:accountable_type]
    assert_nil page.records.sole[:metadata][:accountable_attributes]
    assert_equal "liabilities_unavailable", page.warnings.sole.fetch("code")
    assert_equal "Provider::Plaid::IngestionClient::Error", page.evidence.fetch("liabilities_failure").fetch("error_class")
    assert_nil page.next_cursor
  end

  test "invalid liability ownership is retained as evidence and cannot suppress or enrich the valid balance" do
    credit = @adapter.normalize_account(account_row(type: "credit", subtype: "credit card"), products: %w[liabilities])
    @client.expects(:get_accounts).returns(item_response(accounts: [ account_row(type: "credit", subtype: "credit card") ]))
    invalid = item_response(liabilities: { credit: [ { account_id: "foreign", minimum_payment_amount: "900" } ] })
    @client.expects(:get_liabilities).returns(invalid)
    page = @adapter.fetch_balance(account: credit)
    assert_not page.complete?
    assert_equal BigDecimal("100"), page.records.sole[:balance]
    assert_nil page.records.sole[:metadata][:accountable_attributes]
    assert_equal invalid, page.evidence.fetch("liabilities")
  end

  test "legacy scoped liability objects convert explicit cached monetary Floats" do
    account = @adapter.normalize_account(account_row(type: "credit", subtype: "credit card"))
    raw = { credit: { account_id: "account-1", minimum_payment_amount: 25.25, aprs: [ { apr_percentage: 12.9 } ] }, mortgage: nil, student: nil }
    values = @adapter.normalize_legacy_liabilities(raw, account: account)
    assert_equal BigDecimal("25.25"), values["attributes"]["minimum_payment"]
    assert_equal BigDecimal("12.9"), values["attributes"]["apr"]
    assert_equal 25.25, raw[:credit][:minimum_payment_amount]
  end

  private
    def adapter(**options)
      Provider::AccountData::Plaid.new(**{ client: @client, timezone: "UTC", observed_at: Time.utc(2026, 9, 14, 12), region: "us", item_id: "item-1" }.merge(options))
    end

    def item_response(**values)
      { item: { item_id: "item-1" } }.merge(values)
    end

    def account_row(**values)
      { account_id: "account-1", name: "Checking", type: "depository", subtype: "checking",
        balances: { current: "100", available: "90", iso_currency_code: "USD" } }.merge(values)
    end

    def transaction(**values)
      { transaction_id: "transaction-1", account_id: "account-1", merchant_name: nil, original_description: "Original description",
        amount: "12.50", date: "2026-09-12", iso_currency_code: "USD", pending: false }.merge(values)
    end

    def group_response(**values)
      { added: [], modified: [], removed: [], has_more: false, next_cursor: "next-cursor" }.merge(values)
    end

    def security(**values)
      { security_id: "security-1", ticker_symbol: "AAPL", market_identifier_code: "XNAS" }.merge(values)
    end

    def holding(**values)
      { account_id: "investment", security_id: "security-1", quantity: "2", institution_price: "12.34567890123456789", institution_price_as_of: "2026-09-12", iso_currency_code: "USD" }.merge(values)
    end

    def activity(**values)
      { account_id: "investment", investment_transaction_id: "investment-tx", security_id: "security-1", name: "Investment activity", date: "2026-09-12",
        quantity: "2", price: "10", amount: "20", iso_currency_code: "USD", type: "buy" }.merge(values)
    end
end
