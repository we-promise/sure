require "test_helper"
require "ostruct"

class EnableBankingItem::ImporterBalanceTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @enable_banking_item = EnableBankingItem.create!(
      family: @family,
      name: "CGD PT",
      country_code: "PT",
      application_id: "test_app_id",
      client_certificate: "test_cert",
      session_id: "test_session",
      session_expires_at: 1.day.from_now,
      status: :good
    )

    @enable_banking_account = @enable_banking_item.enable_banking_accounts.create!(
      name: "CGD Current",
      uid: "identification_hash_1",
      account_id: "11111111-1111-1111-1111-111111111111",
      currency: "EUR",
      current_balance: 123.45,
      account_status: "active",
      provider: "enable_banking"
    )

    @mock_provider = OpenStruct.new
    @importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: @mock_provider)
  end

  test "FRESHNESS_BALANCE_TYPES only lists normalized spellings that BALANCE_TYPE_PRIORITY itself accepts" do
    normalized_priority_types = EnableBankingItem::Importer::BALANCE_TYPE_PRIORITY.map { |type| type.delete("_-").downcase }

    assert_empty EnableBankingItem::Importer::FRESHNESS_BALANCE_TYPES - normalized_priority_types,
      "FRESHNESS_BALANCE_TYPES drifted from BALANCE_TYPE_PRIORITY - every accepted spelling here must also be recognized there"
  end

  test "PERIOD_BOUNDARY_TYPES lists both the ISO code and descriptive spelling for OPBD and PRCD" do
    assert_equal %w[opbd openingbooked prcd previouslyclosedbooked].sort, EnableBankingItem::Importer::PERIOD_BOUNDARY_TYPES.sort,
      "PERIOD_BOUNDARY_TYPES must cover both spellings for OPBD/PRCD, mirroring FRESHNESS_BALANCE_TYPES, or the freshness guard silently skips ASPSPs that send the descriptive spelling"
  end

  test "fetch_and_update_balance prefers booked balance before available balance" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "ITAV",
          balance_amount: { amount: "1250.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "ITBD",
          balance_amount: { amount: "50.00", currency: "EUR" },
          credit_debit_indicator: "DBIT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("-50.00"), @enable_banking_account.reload.current_balance
  end

  # Some cards report the credit limit as the booked balance and the available
  # credit as the available balance (mBank PL: ITBD = limit, ITAV = available).
  test "fetch_and_update_balance prefers available balance when the balance is treated as available credit" do
    link_account(CreditCard.create!)
    @enable_banking_account.update!(treat_balance_as_available_credit: true)
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "ITBD",
          balance_amount: { amount: "11500.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "ITAV",
          balance_amount: { amount: "4531.68", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("4531.68"), @enable_banking_account.reload.current_balance
  end

  test "fetch_and_update_balance falls back to booked balance when treated as available credit and no available balance is reported" do
    link_account(CreditCard.create!)
    @enable_banking_account.update!(treat_balance_as_available_credit: true)
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "ITBD",
          balance_amount: { amount: "4531.68", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("4531.68"), @enable_banking_account.reload.current_balance
  end

  test "fetch_and_update_balance keeps booked before expected when treated as available credit" do
    link_account(CreditCard.create!)
    @enable_banking_account.update!(treat_balance_as_available_credit: true)
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "XPCD",
          balance_amount: { amount: "11500.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "ITBD",
          balance_amount: { amount: "4531.68", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("4531.68"), @enable_banking_account.reload.current_balance
  end

  test "fetch_and_update_balance stays booked-first for a non-card account with the available credit flag set" do
    link_account(Depository.create!)
    @enable_banking_account.update!(treat_balance_as_available_credit: true)
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "ITBD",
          balance_amount: { amount: "4531.68", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "ITAV",
          balance_amount: { amount: "11500.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("4531.68"), @enable_banking_account.reload.current_balance
  end

  test "fetch_and_update_balance prefers opening/previously-closed booked balance over expected and available" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "CLAV",
          balance_amount: { amount: "2000.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "XPCD",
          balance_amount: { amount: "1500.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "PRCD",
          balance_amount: { amount: "50.00", currency: "EUR" },
          credit_debit_indicator: "DBIT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("-50.00"), @enable_banking_account.reload.current_balance
  end

  test "fetch_and_update_balance prefers opening booked balance over previously-closed booked balance" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "PRCD",
          balance_amount: { amount: "50.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "openingBooked",
          balance_amount: { amount: "75.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("75.00"), @enable_banking_account.reload.current_balance
  end

  test "fetch_and_update_balance prefers a materially newer expected balance over a stale opening booked balance" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "OPBD",
          reference_date: "2026-09-01",
          balance_amount: { amount: "50.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "XPCD",
          reference_date: "2026-09-25",
          balance_amount: { amount: "75.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("75.00"), @enable_banking_account.reload.current_balance
  end

  test "fetch_and_update_balance keeps the period-boundary balance when reference_date is missing" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "OPBD",
          balance_amount: { amount: "50.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "XPCD",
          reference_date: "2026-09-25",
          balance_amount: { amount: "75.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("50.00"), @enable_banking_account.reload.current_balance
  end

  test "fetch_and_update_balance prefers a materially newer descriptive-spelling balance over a stale opening booked balance" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "OPBD",
          reference_date: "2026-09-01",
          balance_amount: { amount: "50.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "closingAvailable",
          reference_date: "2026-09-25",
          balance_amount: { amount: "75.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("75.00"), @enable_banking_account.reload.current_balance
  end

  test "fetch_and_update_balance prefers a materially newer balance over a stale descriptive-spelling opening booked balance" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "openingBooked",
          reference_date: "2026-09-01",
          balance_amount: { amount: "50.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "closingAvailable",
          reference_date: "2026-09-25",
          balance_amount: { amount: "75.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("75.00"), @enable_banking_account.reload.current_balance
  end

  test "fetch_and_update_balance ignores a newer reference_date on a non-accounting balance type" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "OPBD",
          reference_date: "2026-09-01",
          balance_amount: { amount: "50.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "FWAV",
          reference_date: "2026-09-25",
          balance_amount: { amount: "999.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("50.00"), @enable_banking_account.reload.current_balance
  end

  test "fetch_and_update_balance keeps the period-boundary balance when it is not older than other balances" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "OPBD",
          reference_date: "2026-09-25",
          balance_amount: { amount: "50.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "XPCD",
          reference_date: "2026-09-01",
          balance_amount: { amount: "75.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("50.00"), @enable_banking_account.reload.current_balance
  end

  test "fetch_and_update_balance falls back to the first balance when only unprioritized types are present" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "FWAV",
          balance_amount: { amount: "10.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "OTHR",
          balance_amount: { amount: "999.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("10.00"), @enable_banking_account.reload.current_balance
  end

  test "fetch_and_update_balance uses the account currency's balance from a multi-currency wallet" do
    # PayPal reports one balance per currency under the same type. The stored
    # USD currency is what the old last-entry pick left behind.
    @enable_banking_account.update!(currency: "USD", raw_payload: { "uid" => "paypal", "currency" => "EUR" })
    @mock_provider.stubs(:get_account_balances).returns(balances: paypal_balances)

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    @enable_banking_account.reload
    assert_equal BigDecimal("392.04"), @enable_banking_account.current_balance
    assert_equal "EUR", @enable_banking_account.currency
  end

  test "fetch_and_update_balance uses the first listed currency when the snapshot has none" do
    @enable_banking_account.update!(raw_payload: { "uid" => "paypal" })
    @mock_provider.stubs(:get_account_balances).returns(balances: paypal_balances)

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    @enable_banking_account.reload
    assert_equal BigDecimal("392.04"), @enable_banking_account.current_balance
    assert_equal "EUR", @enable_banking_account.currency
  end

  test "fetch_and_update_balance follows the snapshot currency even when it is not listed first" do
    @enable_banking_account.update!(raw_payload: { "uid" => "paypal", "currency" => "USD" })
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        { balance_type: "CLBD", balance_amount: { amount: "10.00", currency: "EUR" }, credit_debit_indicator: "CRDT" },
        { balance_type: "ITAV", balance_amount: { amount: "30.00", currency: "USD" }, credit_debit_indicator: "CRDT" },
        { balance_type: "ITBD", balance_amount: { amount: "25.00", currency: "USD" }, credit_debit_indicator: "CRDT" }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    @enable_banking_account.reload
    assert_equal BigDecimal("25.00"), @enable_banking_account.current_balance
    assert_equal "USD", @enable_banking_account.currency
  end

  test "fetch_and_update_balance uses the first listed currency when the snapshot reports XXX" do
    # PayPal's accounts endpoint reports the wallet's currency as XXX.
    @enable_banking_account.update!(currency: "USD", raw_payload: { "uid" => "paypal", "currency" => "XXX" })
    @mock_provider.stubs(:get_account_balances).returns(balances: paypal_balances)

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    @enable_banking_account.reload
    assert_equal BigDecimal("392.04"), @enable_banking_account.current_balance
    assert_equal "EUR", @enable_banking_account.currency
  end

  test "fetch_and_update_balance keeps the stored currency when the balance has no valid currency" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [ { balance_type: "CLBD", balance_amount: { amount: "12.00", currency: "XXX" }, credit_debit_indicator: "CRDT" } ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    @enable_banking_account.reload
    assert_equal BigDecimal("12.00"), @enable_banking_account.current_balance
    assert_equal "EUR", @enable_banking_account.currency
  end

  test "fetch_and_update_balance stores the normalized balance currency" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [ { balance_type: "CLBD", balance_amount: { amount: "12.00", currency: " usd " }, credit_debit_indicator: "CRDT" } ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal "USD", @enable_banking_account.reload.currency
  end

  test "fetch_and_update_balance logs funded balances left out in other currencies" do
    @enable_banking_account.update!(raw_payload: { "uid" => "paypal", "currency" => "EUR" })
    balances = paypal_balances
    balances[2] = balances[2].merge(balance_amount: { amount: "15.50", currency: "USD" })
    @mock_provider.stubs(:get_account_balances).returns(balances: balances)

    assert_difference -> { DebugLogEntry.where(category: "provider_sync").count }, 1 do
      assert @importer.send(:fetch_and_update_balance, @enable_banking_account)
    end

    entry = DebugLogEntry.where(category: "provider_sync").order(:created_at).last
    assert_equal "EUR", entry.metadata["currency"]
    assert_equal [ { "currency" => "USD", "balance_type" => "CLBD", "amount" => "15.50" } ], entry.metadata["other_balances"]
  end

  test "fetch_and_update_balance does not log other currencies when the chosen balance has no amount" do
    @enable_banking_account.update!(raw_payload: { "uid" => "paypal", "currency" => "EUR" })
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        { balance_type: "CLBD", balance_amount: { currency: "EUR" }, credit_debit_indicator: "CRDT" },
        { balance_type: "CLBD", balance_amount: { amount: "15.50", currency: "USD" }, credit_debit_indicator: "CRDT" }
      ]
    )

    assert_no_difference -> { DebugLogEntry.where(category: "provider_sync").count } do
      assert_not @importer.send(:fetch_and_update_balance, @enable_banking_account)
    end
    assert_nil @enable_banking_account.reload.current_balance
  end

  test "fetch_and_update_balance does not log empty balances in other currencies" do
    @enable_banking_account.update!(raw_payload: { "uid" => "paypal", "currency" => "EUR" })
    @mock_provider.stubs(:get_account_balances).returns(balances: paypal_balances)

    assert_no_difference -> { DebugLogEntry.where(category: "provider_sync").count } do
      assert @importer.send(:fetch_and_update_balance, @enable_banking_account)
    end
  end

  test "fetch_and_update_balance handles descriptive booked balance types" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "interimAvailable",
          balance_amount: { amount: "2000.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "closingBooked",
          balance_amount: { amount: "321.09", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("321.09"), @enable_banking_account.reload.current_balance
  end

  test "balance endpoint failure marks provider balance unavailable and creates sanitized debug log" do
    error = Provider::EnableBanking::EnableBankingError.new(
      "Bad request to Enable Banking API: {\"error\":\"BALANCES_UNAVAILABLE\"}",
      :bad_request,
      response_data: {
        error: "BALANCES_UNAVAILABLE",
        detail: { account_id: "sensitive_account_id_should_not_be_persisted" }
      }
    )

    @mock_provider.stubs(:get_account_balances).raises(error)

    assert_difference "DebugLogEntry.count", 1 do
      assert_not @importer.send(:fetch_and_update_balance, @enable_banking_account)
    end

    assert_nil @enable_banking_account.reload.current_balance

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "provider_sync_error", entry.category
    assert_equal "warn", entry.level
    assert_equal "enable_banking", entry.provider_key
    assert_equal "bad_request", entry.metadata["error_type"]
    assert_equal "BALANCES_UNAVAILABLE", entry.metadata.dig("provider_error", "error")
    assert_nil entry.metadata["response_data"]
    assert_nil entry.metadata.dig("provider_error", "account_id")
  end

  test "empty balance response marks provider balance unavailable" do
    @mock_provider.stubs(:get_account_balances).returns(balances: [])

    assert_not @importer.send(:fetch_and_update_balance, @enable_banking_account)
    assert_nil @enable_banking_account.reload.current_balance
  end

  test "unusable balance response marks provider balance unavailable" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "CLBD",
          balance_amount: { currency: "EUR" },
          credit_debit_indicator: "CRDT"
        }
      ]
    )

    assert_not @importer.send(:fetch_and_update_balance, @enable_banking_account)
    assert_nil @enable_banking_account.reload.current_balance
  end

  test "import continues transaction sync when balance refresh fails" do
    depository = Depository.create!
    linked_account = Account.create!(
      family: @family,
      name: "CGD linked",
      balance: 123.45,
      cash_balance: 123.45,
      currency: "EUR",
      accountable: depository
    )
    AccountProvider.create!(account: linked_account, provider: @enable_banking_account)

    @enable_banking_item.stubs(:upsert_enable_banking_snapshot!)
    @importer.stubs(:fetch_session_data).returns(accounts: [])
    @importer.expects(:fetch_and_update_balance).with(@enable_banking_account).returns(false)
    @importer.expects(:fetch_and_store_transactions).with(@enable_banking_account).returns(
      success: true,
      transactions_count: 2
    )

    result = @importer.import

    assert result[:success]
    assert_equal 2, result[:transactions_imported]
    assert_equal 0, result[:transactions_failed]
    assert_equal 1, result[:balances_failed]
  end

  test "balance endpoint failure marks unsaved provider balance unavailable" do
    unsaved_account = EnableBankingAccount.new(
      enable_banking_item: @enable_banking_item,
      uid: "unsaved-account",
      current_balance: BigDecimal("123.45"),
      currency: "EUR"
    )

    unsaved_account.stubs(:api_account_id).returns("unsaved-account")

    error = Provider::EnableBanking::EnableBankingError.new(
      "Bad request to Enable Banking API",
      :bad_request,
      response_data: { error: "BALANCES_UNAVAILABLE" }
    )

    @mock_provider.stubs(:get_account_balances).raises(error)

    assert_nothing_raised do
      assert_not @importer.send(:fetch_and_update_balance, unsaved_account)
    end

    assert_nil unsaved_account.current_balance
  end

  test "import refreshes the balance after fetching transactions" do
    link_account(Depository.create!)

    @enable_banking_item.stubs(:upsert_enable_banking_snapshot!)
    @importer.stubs(:fetch_session_data).returns(accounts: [])
    order = sequence("balance after transactions")
    @importer.expects(:fetch_and_store_transactions).with(@enable_banking_account).returns(success: true, transactions_count: 0).in_sequence(order)
    @importer.expects(:fetch_and_update_balance).with(@enable_banking_account).returns(true).in_sequence(order)

    @importer.import
  end

  test "import still refreshes the balance when the transaction fetch raises" do
    link_account(Depository.create!)

    @enable_banking_item.stubs(:upsert_enable_banking_snapshot!)
    @importer.stubs(:fetch_session_data).returns(accounts: [])
    @importer.stubs(:fetch_and_store_transactions).raises(StandardError, "boom")
    @importer.expects(:fetch_and_update_balance).with(@enable_banking_account).returns(true)

    result = @importer.import

    assert_equal 1, result[:transactions_failed]
    assert_equal 0, result[:balances_failed]
  end

  test "a failed import leaves the anchor's verification untouched" do
    link_account(Depository.create!)
    @enable_banking_account.update!(balance_verified: false)

    @enable_banking_item.stubs(:upsert_enable_banking_snapshot!)
    @importer.stubs(:fetch_session_data).returns(accounts: [])
    @importer.stubs(:fetch_and_store_transactions).raises(StandardError, "boom")
    stub_balances(clbd("950.00"))

    result = @importer.import

    # The syncer stops before the processor whenever the import fails, so this
    # balance never becomes the anchor and must not vouch for the old one.
    assert_not result[:success]
    @enable_banking_account.reload
    assert_equal BigDecimal("950.00"), @enable_banking_account.current_balance
    assert_not @enable_banking_account.balance_verified?
    assert @enable_banking_account.balance_evidence_verified?
  end

  test "duplicate CLBD balances without metadata pick the lower one on a depository account (#3188)" do
    link_account(Depository.create!)
    stub_balances(clbd("1234.56"), clbd("5834.56"))

    assert_difference "DebugLogEntry.count", 1 do
      assert @importer.send(:fetch_and_update_balance, @enable_banking_account)
    end

    @enable_banking_account.reload
    assert_equal BigDecimal("1234.56"), @enable_banking_account.current_balance
    assert_not @enable_banking_account.balance_evidence_verified?, "a heuristic pick must not become a trusted anchor"

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "provider_sync_warning", entry.category
    assert_equal "lowest", entry.metadata["stage"]
    assert_equal 2, entry.metadata["candidates"].size
  end

  test "the same duplicate balances are logged only once across syncs" do
    link_account(Depository.create!)
    stub_balances(clbd("1234.56"), clbd("5834.56"))

    assert_difference "DebugLogEntry.count", 1 do
      2.times { assert @importer.send(:fetch_and_update_balance, @enable_banking_account) }
    end
  end

  test "a single balance per type counts as evidence and logs nothing" do
    stub_balances(clbd("1234.56"))

    assert_no_difference "DebugLogEntry.count" do
      assert @importer.send(:fetch_and_update_balance, @enable_banking_account)
    end

    assert @enable_banking_account.reload.balance_evidence_verified?
  end

  test "duplicate balances in different currencies are narrowed by currency before any tiebreak" do
    link_account(Depository.create!)
    @enable_banking_account.update!(raw_payload: { "currency" => "EUR" })
    stub_balances(clbd("900.00", currency: "USD"), clbd("1234.56"))

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    @enable_banking_account.reload
    assert_equal BigDecimal("1234.56"), @enable_banking_account.current_balance
    assert @enable_banking_account.balance_evidence_verified?
    assert_empty DebugLogEntry.where("metadata ->> 'stage' IS NOT NULL")
  end

  test "duplicate balances pointing to different bookings prefer the newer booking" do
    link_account(CreditCard.create!)
    @enable_banking_account.update!(raw_transactions_payload: [
      booked_tx("ref-old", 3.days.ago.to_date, "10.00"),
      booked_tx("ref-new", 1.day.ago.to_date, "20.00")
    ])
    stub_balances(
      clbd("100.00", last_committed_transaction: "ref-old"),
      clbd("80.00", last_committed_transaction: "ref-new")
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("80.00"), @enable_banking_account.reload.current_balance
    assert_equal "last_committed_transaction", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "a booking reference reused with different dates does not decide the tie" do
    link_account(CreditCard.create!)
    @enable_banking_account.update!(raw_transactions_payload: [
      booked_tx("ref-a", 3.days.ago.to_date, "10.00"),
      booked_tx("ref-b", 1.day.ago.to_date, "20.00"),
      booked_tx("ref-a", Date.current, "30.00")
    ])
    stub_balances(
      clbd("80.00", last_committed_transaction: "ref-b"),
      clbd("100.00", last_committed_transaction: "ref-a")
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("80.00"), @enable_banking_account.reload.current_balance
    assert_equal "first", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "duplicate balances pointing to the same booking fall through to later stages" do
    link_account(Depository.create!)
    @enable_banking_account.update!(raw_transactions_payload: [ booked_tx("ref-1", 1.day.ago.to_date, "10.00") ])
    stub_balances(
      clbd("5834.56", last_committed_transaction: "ref-1"),
      clbd("1234.56", last_committed_transaction: "ref-1")
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("1234.56"), @enable_banking_account.reload.current_balance
    assert_equal "lowest", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "a gap equal to the credit limit identifies the overdraft-inclusive balance" do
    link_account(Depository.create!)
    @enable_banking_account.update!(credit_limit: BigDecimal("4600.00"))
    stub_balances(clbd("5834.56"), clbd("1234.56"))

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("1234.56"), @enable_banking_account.reload.current_balance
    entry = DebugLogEntry.order(:created_at).last
    assert_equal "credit_limit", entry.metadata["stage"]
    assert_equal "4600.0", entry.metadata["credit_limit"]
  end

  test "a verified previous anchor minus booked outflows picks the matching balance" do
    account = link_account(Depository.create!)
    create_anchor(account, amount: 1000, date: 2.days.ago.to_date)
    @enable_banking_account.update!(
      balance_verified: true,
      raw_transactions_payload: [ booked_tx("ref-1", 1.day.ago.to_date, "50.00", indicator: "DBIT") ]
    )
    # 1000 - 50 = 950. Adding the outflow instead (1050) would pick 1100.
    stub_balances(clbd("1100.00"), clbd("950.00"))

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("950.00"), @enable_banking_account.reload.current_balance
    assert @enable_banking_account.balance_evidence_verified?
    assert_equal "anchor", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "the anchor check abstains when bookings on the anchor day change the answer" do
    account = link_account(Depository.create!)
    create_anchor(account, amount: 1000, date: 2.days.ago.to_date)
    @enable_banking_account.update!(
      balance_verified: true,
      raw_transactions_payload: [ booked_tx("ref-same-day", 2.days.ago.to_date, "700.00", indicator: "DBIT") ]
    )
    # Without the anchor-day booking 1000 matches, with it 300 does.
    stub_balances(clbd("1000.00"), clbd("300.00"))

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("300.00"), @enable_banking_account.reload.current_balance
    assert_equal "lowest", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "the anchor check abstains when a booked amount cannot be parsed" do
    account = link_account(Depository.create!)
    create_anchor(account, amount: 1000, date: 2.days.ago.to_date)
    @enable_banking_account.update!(
      balance_verified: true,
      raw_transactions_payload: [ booked_tx("ref-bad", 1.day.ago.to_date, "not-a-number", indicator: "DBIT") ]
    )
    # Treating the bad amount as 0 would confirm 1000 as the anchor-backed pick.
    stub_balances(clbd("1000.00"), clbd("950.00"))

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("950.00"), @enable_banking_account.reload.current_balance
    assert_not @enable_banking_account.balance_evidence_verified?
    assert_equal "lowest", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "the anchor check falls back to value_date when booking_date is missing" do
    account = link_account(Depository.create!)
    create_anchor(account, amount: 1000, date: 2.days.ago.to_date)
    tx = booked_tx("ref-1", 1.day.ago.to_date, "50.00", indicator: "DBIT")
    tx["value_date"] = tx.delete("booking_date")
    @enable_banking_account.update!(balance_verified: true, raw_transactions_payload: [ tx ])
    stub_balances(clbd("1000.00"), clbd("950.00"))

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("950.00"), @enable_banking_account.reload.current_balance
    assert_equal "anchor", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "the anchor check ignores pending rows and bookings before the anchor date" do
    account = link_account(Depository.create!)
    create_anchor(account, amount: 1000, date: 2.days.ago.to_date)
    @enable_banking_account.update!(
      balance_verified: true,
      raw_transactions_payload: [
        booked_tx("ref-before", 3.days.ago.to_date, "300.00", indicator: "DBIT"),
        booked_tx("ref-pending", 1.day.ago.to_date, "300.00", indicator: "DBIT").merge("status" => "PDNG", "_pending" => true),
        booked_tx("ref-in", 1.day.ago.to_date, "100.00", indicator: "CRDT")
      ]
    )
    stub_balances(clbd("1100.00"), clbd("700.00"))

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("1100.00"), @enable_banking_account.reload.current_balance
    assert_equal "anchor", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "the anchor check is skipped when the previous balance was not verified" do
    account = link_account(Depository.create!)
    create_anchor(account, amount: 1000, date: 2.days.ago.to_date)
    @enable_banking_account.update!(balance_verified: false, raw_transactions_payload: [])
    stub_balances(clbd("1000.00"), clbd("800.00"))

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("800.00"), @enable_banking_account.reload.current_balance
    assert_equal "lowest", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "an anchor tie is broken by the newer last_change_date_time" do
    account = link_account(Depository.create!)
    create_anchor(account, amount: 1000, date: 2.days.ago.to_date)
    @enable_banking_account.update!(balance_verified: true, raw_transactions_payload: [])
    stub_balances(
      clbd("999.99", last_change_date_time: "2026-09-29T08:00:00Z"),
      clbd("1000.00", last_change_date_time: "2026-09-30T08:00:00Z")
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("1000.00"), @enable_banking_account.reload.current_balance
    assert_not @enable_banking_account.balance_evidence_verified?
    assert @enable_banking_account.balance_verified?, "only the processor may change the anchor's verification"
    assert_equal "anchor_timestamp", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "the anchor check abstains when no candidate matches the expected balance" do
    account = link_account(Depository.create!)
    create_anchor(account, amount: 1000, date: 2.days.ago.to_date)
    @enable_banking_account.update!(balance_verified: true, raw_transactions_payload: [])
    # 1500 is closer to 1000 than 1600 but still no match, so it is no evidence.
    stub_balances(clbd("1600.00"), clbd("1500.00"))

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("1500.00"), @enable_banking_account.reload.current_balance
    assert_not @enable_banking_account.balance_evidence_verified?
    assert_equal "lowest", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "duplicate fresher balances go through the same tiebreak regardless of response order" do
    link_account(Depository.create!)
    itav = lambda do |amount|
      { balance_type: "ITAV", balance_amount: { amount: amount, currency: "EUR" }, credit_debit_indicator: "CRDT", reference_date: "2026-09-29" }
    end
    opbd = { balance_type: "OPBD", balance_amount: { amount: "100.00", currency: "EUR" }, credit_debit_indicator: "CRDT", reference_date: "2026-09-01" }

    [ [ "900.00", "200.00" ], [ "200.00", "900.00" ] ].each do |first, second|
      stub_balances(opbd, itav.call(first), itav.call(second))

      assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

      assert_equal BigDecimal("200.00"), @enable_banking_account.reload.current_balance, "order #{first}, #{second}"
      assert_not @enable_banking_account.balance_evidence_verified?
      assert_equal "lowest", DebugLogEntry.order(:created_at).last.metadata["stage"]
    end
  end

  test "an older entry of the fresher type keeps an evidence-backed fresher pick unverified" do
    stub_balances(
      { balance_type: "OPBD", balance_amount: { amount: "100.00", currency: "EUR" }, credit_debit_indicator: "CRDT", reference_date: "2026-09-01" },
      { balance_type: "ITAV", balance_amount: { amount: "150.00", currency: "EUR" }, credit_debit_indicator: "CRDT", reference_date: "2026-09-15" },
      { balance_type: "ITAV", balance_amount: { amount: "900.00", currency: "USD" }, credit_debit_indicator: "CRDT", reference_date: "2026-09-29" },
      { balance_type: "ITAV", balance_amount: { amount: "200.00", currency: "EUR" }, credit_debit_indicator: "CRDT", reference_date: "2026-09-29" }
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    @enable_banking_account.reload
    assert_equal BigDecimal("200.00"), @enable_banking_account.current_balance
    assert_not @enable_banking_account.balance_evidence_verified?
  end

  test "several balances of unknown types are not treated as evidence" do
    @enable_banking_account.update!(balance_evidence_verified: true)
    stub_balances(
      { balance_type: "XYZ1", balance_amount: { amount: "100.00", currency: "EUR" }, credit_debit_indicator: "CRDT" },
      { balance_type: "XYZ2", balance_amount: { amount: "900.00", currency: "EUR" }, credit_debit_indicator: "CRDT" }
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    @enable_banking_account.reload
    assert_equal BigDecimal("100.00"), @enable_banking_account.current_balance
    assert_not @enable_banking_account.balance_evidence_verified?
  end

  test "a fresher balance whose type is duplicated is not marked as verified" do
    @enable_banking_account.update!(balance_evidence_verified: true)
    stub_balances(
      { balance_type: "OPBD", balance_amount: { amount: "100.00", currency: "EUR" }, credit_debit_indicator: "CRDT", reference_date: "2026-09-01" },
      { balance_type: "ITAV", balance_amount: { amount: "200.00", currency: "EUR" }, credit_debit_indicator: "CRDT", reference_date: "2026-09-29" },
      { balance_type: "ITAV", balance_amount: { amount: "900.00", currency: "EUR" }, credit_debit_indicator: "CRDT", reference_date: "2026-09-29" }
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_not @enable_banking_account.reload.balance_evidence_verified?
  end

  test "import counts a raising balance refresh as failed and keeps syncing" do
    link_account(Depository.create!)

    @enable_banking_item.stubs(:upsert_enable_banking_snapshot!)
    @importer.stubs(:fetch_session_data).returns(accounts: [])
    @importer.stubs(:fetch_and_store_transactions).returns(success: true, transactions_count: 1)
    @importer.stubs(:fetch_and_update_balance).raises(ActiveRecord::StatementInvalid, "lock timeout")

    result = nil
    assert_nothing_raised { result = @importer.import }

    assert_equal 1, result[:balances_failed]
    assert_equal 1, result[:transactions_imported]
  end

  test "duplicate balances on a credit card keep the first reported entry" do
    link_account(CreditCard.create!)
    stub_balances(clbd("500.00"), clbd("100.00"))

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("500.00"), @enable_banking_account.reload.current_balance
    assert_equal "first", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "a gap equal to the credit limit decides before the booking references" do
    link_account(Depository.create!)
    @enable_banking_account.update!(
      credit_limit: BigDecimal("4580.00"),
      raw_transactions_payload: [
        booked_tx("ref-a", 2.days.ago.to_date, "10.00"),
        booked_tx("ref-b", 1.day.ago.to_date, "20.00")
      ]
    )
    stub_balances(
      clbd("1234.56", last_committed_transaction: "ref-a"),
      clbd("5814.56", last_committed_transaction: "ref-b")
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("1234.56"), @enable_banking_account.reload.current_balance
    assert_equal "credit_limit", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "an evidence-backed tie in the fresher type stays verified when it has no older entries" do
    link_account(Depository.create!)
    @enable_banking_account.update!(credit_limit: BigDecimal("4600.00"))
    itav = lambda do |amount|
      { balance_type: "ITAV", balance_amount: { amount: amount, currency: "EUR" }, credit_debit_indicator: "CRDT", reference_date: "2026-09-29" }
    end
    stub_balances(
      { balance_type: "OPBD", balance_amount: { amount: "100.00", currency: "EUR" }, credit_debit_indicator: "CRDT", reference_date: "2026-09-01" },
      itav.call("5834.56"),
      itav.call("1234.56")
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    @enable_banking_account.reload
    assert_equal BigDecimal("1234.56"), @enable_banking_account.current_balance
    assert @enable_banking_account.balance_evidence_verified?
    assert_equal "credit_limit", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "the same amount reported twice is no tie" do
    link_account(Depository.create!)
    stub_balances(clbd("1000.00"), clbd("1000.00"))

    assert_no_difference -> { DebugLogEntry.count } do
      assert @importer.send(:fetch_and_update_balance, @enable_banking_account)
    end

    @enable_banking_account.reload
    assert_equal BigDecimal("1000.00"), @enable_banking_account.current_balance
    assert @enable_banking_account.balance_evidence_verified?
  end

  test "a duplicated period boundary balance that a fresher balance replaces is not logged" do
    link_account(Depository.create!)
    opbd = lambda do |amount|
      { balance_type: "OPBD", balance_amount: { amount: amount, currency: "EUR" }, credit_debit_indicator: "CRDT", reference_date: "2026-09-01" }
    end
    stub_balances(
      opbd.call("100.00"),
      opbd.call("900.00"),
      { balance_type: "ITAV", balance_amount: { amount: "200.00", currency: "EUR" }, credit_debit_indicator: "CRDT", reference_date: "2026-09-29" }
    )

    assert_no_difference -> { DebugLogEntry.count } do
      assert @importer.send(:fetch_and_update_balance, @enable_banking_account)
    end

    @enable_banking_account.reload
    assert_equal BigDecimal("200.00"), @enable_banking_account.current_balance
    assert @enable_banking_account.balance_evidence_verified?
  end

  test "the anchor check leaves unidentified card holds out of the booked flows" do
    account = link_account(Depository.create!)
    create_anchor(account, amount: 1000, date: 2.days.ago.to_date)
    hold = {
      "entry_reference" => nil,
      "transaction_id" => nil,
      "status" => "BOOK",
      "booking_date" => 1.day.ago.to_date.iso8601,
      "credit_debit_indicator" => "DBIT",
      "transaction_amount" => { "amount" => "50.00", "currency" => "EUR" },
      "remittance_information" => [ "474836xxxxxx6879 003015315475" ]
    }
    @enable_banking_account.update!(balance_verified: true, raw_transactions_payload: [ hold ])
    stub_balances(clbd("1000.00"), clbd("950.00"))

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("1000.00"), @enable_banking_account.reload.current_balance
    assert_equal "anchor", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "the anchor check ignores an anchor written before the provider account was linked" do
    account = link_account(Depository.create!)
    create_anchor(account, amount: 1000, date: 2.days.ago.to_date)
    @enable_banking_account.account_provider.update_column(:created_at, 1.hour.from_now)
    @enable_banking_account.update!(balance_verified: true, raw_transactions_payload: [])
    stub_balances(clbd("1000.00"), clbd("800.00"))

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("800.00"), @enable_banking_account.reload.current_balance
    assert_equal "lowest", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "an unchanged tie is logged once, a changed one again" do
    link_account(Depository.create!)
    stub_balances(clbd("5834.56"), clbd("1234.56"))

    assert_difference -> { DebugLogEntry.count }, 1 do
      2.times { assert @importer.send(:fetch_and_update_balance, @enable_banking_account) }
    end

    stub_balances(clbd("5800.00"), clbd("1200.00"))
    assert_difference -> { DebugLogEntry.count }, 1 do
      assert @importer.send(:fetch_and_update_balance, @enable_banking_account)
    end
  end

  test "the same tie reported in a different order is not logged again" do
    link_account(Depository.create!)

    assert_difference -> { DebugLogEntry.count }, 1 do
      stub_balances(clbd("5834.56"), clbd("1234.56"))
      assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

      stub_balances(clbd("1234.56"), clbd("5834.56"))
      assert @importer.send(:fetch_and_update_balance, @enable_banking_account)
    end
  end

  test "the anchor check abstains when a booked flow has no usable date" do
    account = link_account(Depository.create!)
    create_anchor(account, amount: 1000, date: 2.days.ago.to_date)
    undated = booked_tx("ref-1", 1.day.ago.to_date, "100.00").merge("booking_date" => nil)
    @enable_banking_account.update!(balance_verified: true, raw_transactions_payload: [ undated ])
    stub_balances(clbd("1000.00"), clbd("900.00"))

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("900.00"), @enable_banking_account.reload.current_balance
    assert_not @enable_banking_account.balance_evidence_verified?
    assert_equal "lowest", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "the anchor check dates timestamped bookings in the family timezone" do
    @family.update!(timezone: "America/New_York")
    travel_to Time.zone.parse("2026-10-10 12:00:00 UTC") do
      account = link_account(Depository.create!)
      create_anchor(account, amount: 1000, date: Date.new(2026, 10, 9))
      # 02:00 UTC on the 9th is still the 8th in New York, so the booking is
      # before the anchor and the expected balance stays 1000.
      early = booked_tx("ref-1", Date.new(2026, 10, 9), "50.00").merge("booking_date" => "2026-10-09T02:00:00Z")
      @enable_banking_account.update!(balance_verified: true, raw_transactions_payload: [ early ])
      stub_balances(clbd("950.00"), clbd("1000.00"))

      assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

      assert_equal BigDecimal("1000.00"), @enable_banking_account.reload.current_balance
      assert_equal "anchor", DebugLogEntry.order(:created_at).last.metadata["stage"]
    end
  end

  private

    def link_account(accountable)
      account = Account.create!(
        family: @family,
        name: "CGD linked",
        balance: 123.45,
        cash_balance: 123.45,
        currency: "EUR",
        accountable: accountable
      )
      AccountProvider.create!(account: account, provider: @enable_banking_account)
      @enable_banking_account.reload
      account
    end

    def create_anchor(account, amount:, date:)
      account.entries.create!(
        date: date,
        name: "Current balance",
        amount: amount,
        currency: "EUR",
        entryable: Valuation.new(kind: "current_anchor")
      )
    end

    def stub_balances(*balances)
      @mock_provider.stubs(:get_account_balances).returns(balances: balances)
    end

    def clbd(amount, currency: "EUR", **metadata)
      {
        name: "Accounting balance",
        balance_type: "CLBD",
        balance_amount: { amount: amount, currency: currency },
        credit_debit_indicator: "CRDT",
        last_change_date_time: nil,
        reference_date: nil,
        last_committed_transaction: nil
      }.merge(metadata)
    end

    def booked_tx(entry_reference, booking_date, amount, indicator: "DBIT")
      {
        "entry_reference" => entry_reference,
        "status" => "BOOK",
        "booking_date" => booking_date.iso8601,
        "credit_debit_indicator" => indicator,
        "transaction_amount" => { "amount" => amount, "currency" => "EUR" }
      }
    end

    # Shaped like PayPal's response: the primary EUR balance first, then empty
    # CAD and USD balances under the same type.
    def paypal_balances
      %w[EUR CAD USD].zip(%w[392.04 0.00 0.00]).map do |currency, amount|
        { balance_type: "CLBD", balance_amount: { amount: amount, currency: currency }, credit_debit_indicator: "CRDT" }
      end
    end
end
