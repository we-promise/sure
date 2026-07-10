require "test_helper"

class Family::DataImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
  end

  test "imports accounts with accountable data" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "old-account-1",
          name: "Test Checking",
          balance: "1500.00",
          currency: "USD",
          accountable_type: "Depository",
          accountable: { subtype: "checking" }
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    result = importer.import!

    assert_equal 1, result[:accounts].count
    account = result[:accounts].first
    assert_equal "Test Checking", account.name
    assert_equal 1500.0, account.balance.to_f
    assert_equal "USD", account.currency
    assert_equal "Depository", account.accountable_type
  end

  test "imports account auto_match_transfers opt-out and defaults it for older exports" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "old-account-1",
          name: "No Auto Match",
          balance: "100.00",
          currency: "USD",
          accountable_type: "Depository",
          auto_match_transfers: false
        }
      },
      {
        type: "Account",
        data: {
          id: "old-account-2",
          name: "Legacy Export",
          balance: "100.00",
          currency: "USD",
          accountable_type: "Depository"
        }
      }
    ])

    Family::DataImporter.new(@family, ndjson).import!

    assert_not @family.accounts.find_by!(name: "No Auto Match").auto_match_transfers?
    assert @family.accounts.find_by!(name: "Legacy Export").auto_match_transfers?
  end

  test "reimporting a legacy export does not clobber an existing auto_match_transfers opt-out" do
    session = @family.import_sessions.create!(expected_chunks: 1)
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "acct-1",
          name: "Legacy Reimport",
          balance: "100.00",
          currency: "USD",
          accountable_type: "Depository"
        }
      }
    ])

    Family::DataImporter.new(@family, ndjson, import_session: session).import!

    account = @family.accounts.find_by!(name: "Legacy Reimport")
    account.update!(auto_match_transfers: false)

    Family::DataImporter.new(@family, ndjson, import_session: session).import!

    assert_not account.reload.auto_match_transfers?, "Reprocessing a legacy export must not reset the opt-out"
  end

  test "imports non-destructive account status from ndjson" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "disabled-account",
          name: "Closed Checking",
          balance: "0.00",
          currency: "USD",
          accountable_type: "Depository",
          status: "disabled"
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    result = importer.import!

    account = result[:accounts].first
    assert_equal "Closed Checking", account.name
    assert_equal "disabled", account.status
  end

  test "does not import pending deletion account status" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "pending-delete-account",
          name: "Pending Delete Checking",
          balance: "0.00",
          currency: "USD",
          accountable_type: "Depository",
          status: "pending_deletion"
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    result = importer.import!

    account = result[:accounts].first
    assert_equal "Pending Delete Checking", account.name
    assert_equal "active", account.status
  end

  test "imports raw balance history records" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "acct-1",
          name: "Balance History Checking",
          balance: "1200.00",
          currency: "USD",
          accountable_type: "Depository"
        }
      },
      {
        type: "Balance",
        data: {
          id: "balance-1",
          account_id: "acct-1",
          date: "2024-01-31",
          balance: "1200.00",
          currency: "USD",
          cash_balance: "1100.00",
          start_cash_balance: "1000.00",
          start_non_cash_balance: "0.00",
          cash_inflows: "300.00",
          cash_outflows: "200.00",
          non_cash_inflows: "0.00",
          non_cash_outflows: "0.00",
          net_market_flows: "0.00",
          cash_adjustments: "0.00",
          non_cash_adjustments: "0.00",
          flows_factor: 1
        }
      }
    ])

    Family::DataImporter.new(@family, ndjson).import!

    account = @family.accounts.find_by!(name: "Balance History Checking")
    balance = account.balances.find_by!(date: Date.parse("2024-01-31"), currency: "USD")

    assert_equal 1200.0, balance.balance.to_f
    assert_equal 1100.0, balance.cash_balance.to_f
    assert_equal 1000.0, balance.start_cash_balance.to_f
    assert_equal 300.0, balance.cash_inflows.to_f
    assert_equal 200.0, balance.cash_outflows.to_f
    assert_equal 1, balance.flows_factor
  end

  test "counts skipped balance rows with blank account references once" do
    ndjson = build_ndjson([
      {
        type: "Balance",
        data: {
          id: "balance-1",
          account_id: "",
          date: "2024-01-31",
          balance: "1200.00",
          currency: "USD"
        }
      }
    ])

    result = Family::DataImporter.new(@family, ndjson).import!

    assert_equal 1, result.dig(:summary, "balances", "skipped")
    assert_not Balance.exists?(date: Date.iso8601("2024-01-31"), currency: "USD", balance: BigDecimal("1200.00"))
  end

  test "imports duplicate raw balance records idempotently by account date and currency" do
    balance_record = {
      type: "Balance",
      data: {
        id: "balance-1",
        account_id: "acct-1",
        date: "2024-01-31",
        balance: "1200.00",
        currency: "USD",
        cash_balance: "1100.00",
        flows_factor: 1
      }
    }

    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "acct-1",
          name: "Idempotent Balance Checking",
          balance: "1200.00",
          currency: "USD",
          accountable_type: "Depository"
        }
      },
      balance_record,
      balance_record.deep_merge(data: { id: "balance-1-duplicate", balance: "1300.00", cash_balance: "1250.00" })
    ])

    Family::DataImporter.new(@family, ndjson).import!

    account = @family.accounts.find_by!(name: "Idempotent Balance Checking")
    assert_equal 1, account.balances.where(date: Date.parse("2024-01-31"), currency: "USD").count

    balance = account.balances.find_by!(date: Date.parse("2024-01-31"), currency: "USD")
    assert_equal 1300.0, balance.balance.to_f
    assert_equal 1250.0, balance.cash_balance.to_f
  end

  test "preserves omitted raw balance components on duplicate records" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "acct-1",
          name: "Partial Balance Checking",
          balance: "1200.00",
          currency: "USD",
          accountable_type: "Depository"
        }
      },
      {
        type: "Balance",
        data: {
          id: "balance-1",
          account_id: "acct-1",
          date: "2024-01-31",
          balance: "1200.00",
          currency: "USD",
          cash_balance: "1100.00",
          cash_inflows: "300.00",
          cash_outflows: "200.00",
          flows_factor: -1
        }
      },
      {
        type: "Balance",
        data: {
          id: "balance-1-partial",
          account_id: "acct-1",
          date: "2024-01-31",
          balance: "1300.00",
          currency: "USD"
        }
      }
    ])

    Family::DataImporter.new(@family, ndjson).import!

    account = @family.accounts.find_by!(name: "Partial Balance Checking")
    balance = account.balances.find_by!(date: Date.parse("2024-01-31"), currency: "USD")

    assert_equal 1300.0, balance.balance.to_f
    assert_equal 1100.0, balance.cash_balance.to_f
    assert_equal 300.0, balance.cash_inflows.to_f
    assert_equal 200.0, balance.cash_outflows.to_f
    assert_equal(-1, balance.flows_factor)
  end

  test "dates synthesized account opening balance before imported balance history" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "acct-1",
          name: "Balance Anchored Checking",
          balance: "500.00",
          currency: "USD",
          accountable_type: "Depository"
        }
      },
      {
        type: "Balance",
        data: {
          id: "balance-1",
          account_id: "acct-1",
          date: "2024-02-01",
          balance: "500.00",
          currency: "USD"
        }
      }
    ])

    Family::DataImporter.new(@family, ndjson).import!

    account = @family.accounts.find_by!(name: "Balance Anchored Checking")
    opening_anchor = account.valuations.opening_anchor.first

    assert_not_nil opening_anchor
    assert_equal Date.parse("2024-01-31"), opening_anchor.entry.date
  end

  test "dates synthesized account opening balance before oldest imported activity" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "acct-1",
          name: "Main Account",
          balance: "5000",
          currency: "USD",
          accountable_type: "Depository"
        }
      },
      {
        type: "Transaction",
        data: {
          id: "txn-1",
          account_id: "acct-1",
          date: "2020-04-02",
          amount: "-50.00",
          name: "Grocery Store",
          currency: "USD"
        }
      }
    ])

    Family::DataImporter.new(@family, ndjson).import!

    account = @family.accounts.find_by!(name: "Main Account")
    opening_anchor = account.valuations.opening_anchor.first

    assert_not_nil opening_anchor
    assert_equal Date.parse("2020-04-01"), opening_anchor.entry.date
  end

  test "clamps explicit account opening balance dates before imported activity" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "acct-1",
          name: "Main Account",
          balance: "5000",
          currency: "USD",
          accountable_type: "Depository",
          opening_balance_date: "2020-04-02"
        }
      },
      {
        type: "Transaction",
        data: {
          id: "txn-1",
          account_id: "acct-1",
          date: "2020-04-02",
          amount: "-50.00",
          name: "Grocery Store",
          currency: "USD"
        }
      }
    ])

    Family::DataImporter.new(@family, ndjson).import!

    account = @family.accounts.find_by!(name: "Main Account")
    opening_anchor = account.valuations.opening_anchor.first

    assert_not_nil opening_anchor
    assert_equal Date.parse("2020-04-01"), opening_anchor.entry.date
  end

  test "imports explicit opening anchor valuations without synthesizing duplicates" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "acct-1",
          name: "Main Account",
          balance: "5000",
          currency: "USD",
          accountable_type: "Depository"
        }
      },
      {
        type: "Valuation",
        data: {
          id: "val-opening",
          account_id: "acct-1",
          date: "2020-04-01",
          amount: "5000",
          name: "Opening balance",
          currency: "USD",
          kind: "opening_anchor"
        }
      }
    ])

    Family::DataImporter.new(@family, ndjson).import!

    account = @family.accounts.find_by!(name: "Main Account")
    opening_anchors = account.valuations.opening_anchor.to_a

    assert_equal 1, opening_anchors.count
    assert_equal Date.parse("2020-04-01"), opening_anchors.first.entry.date
    assert_equal 5000.0, opening_anchors.first.entry.amount.to_f
  end

  test "skips synthesized opening anchor for authoritative balance history imports" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "acct-1",
          name: "Imported With Full History",
          balance: "5000",
          currency: "USD",
          accountable_type: "Depository",
          authoritative_balance_history: true
        }
      },
      {
        type: "Valuation",
        data: {
          id: "val-1",
          account_id: "acct-1",
          date: "2020-04-01",
          amount: "4900",
          name: "Imported balance",
          currency: "USD",
          kind: "reconciliation"
        }
      }
    ])

    Family::DataImporter.new(@family, ndjson).import!

    account = @family.accounts.find_by!(name: "Imported With Full History")

    assert_equal 5000.0, account.balance.to_f
    assert_empty account.valuations.opening_anchor
    assert_equal 1, account.valuations.reconciliation.count
  end

  test "imports categories with parent relationships" do
    ndjson = build_ndjson([
      {
        type: "Category",
        data: {
          id: "cat-parent",
          name: "Shopping",
          color: "#FF5733",
          classification: "expense"
        }
      },
      {
        type: "Category",
        data: {
          id: "cat-child",
          name: "Groceries",
          color: "#33FF57",
          classification: "expense",
          parent_id: "cat-parent"
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    importer.import!

    parent = @family.categories.find_by(name: "Shopping")
    child = @family.categories.find_by(name: "Groceries")

    assert_not_nil parent
    assert_not_nil child
    assert_equal parent.id, child.parent_id
  end

  test "imports tags" do
    ndjson = build_ndjson([
      {
        type: "Tag",
        data: {
          id: "tag-1",
          name: "Important",
          color: "#FF0000"
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    importer.import!

    tag = @family.tags.find_by(name: "Important")
    assert_not_nil tag
    assert_equal "#FF0000", tag.color
  end

  test "imports tags with deterministic fallback color when source omits color" do
    ndjson = build_ndjson([
      {
        type: "Tag",
        data: {
          id: "tag-1",
          name: "Important"
        }
      }
    ])

    Family::DataImporter.new(@family, ndjson).import!

    tag = @family.tags.find_by!(name: "Important")
    assert_equal Tag::COLORS.first, tag.color
  end

  test "imports merchants" do
    ndjson = build_ndjson([
      {
        type: "Merchant",
        data: {
          id: "merchant-1",
          name: "Amazon"
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    importer.import!

    merchant = @family.merchants.find_by(name: "Amazon")
    assert_not_nil merchant
  end

  test "imports recurring transactions with remapped account and merchant references" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "acct-1",
          name: "Main Checking",
          balance: "5000",
          currency: "USD",
          accountable_type: "Depository"
        }
      },
      {
        type: "Merchant",
        data: {
          id: "merchant-1",
          name: "Internet Provider"
        }
      },
      {
        type: "RecurringTransaction",
        data: {
          id: "recurring-1",
          account_id: "acct-1",
          merchant_id: "merchant-1",
          amount: "-89.99",
          currency: "USD",
          expected_day_of_month: 14,
          last_occurrence_date: "2024-01-14",
          next_expected_date: "2024-02-14",
          status: "active",
          occurrence_count: 6,
          manual: true,
          expected_amount_min: "-95.00",
          expected_amount_max: "-85.00",
          expected_amount_avg: "-89.99"
        }
      }
    ])

    Family::DataImporter.new(@family, ndjson).import!

    recurring_transaction = @family.recurring_transactions.first
    assert_not_nil recurring_transaction
    assert_equal "Main Checking", recurring_transaction.account.name
    assert_equal "Internet Provider", recurring_transaction.merchant.name
    assert_equal(-89.99, recurring_transaction.amount.to_f)
    assert_equal "USD", recurring_transaction.currency
    assert_equal 14, recurring_transaction.expected_day_of_month
    assert_equal Date.parse("2024-01-14"), recurring_transaction.last_occurrence_date
    assert_equal Date.parse("2024-02-14"), recurring_transaction.next_expected_date
    assert_equal "active", recurring_transaction.status
    assert_equal 6, recurring_transaction.occurrence_count
    assert_equal true, recurring_transaction.manual
    assert_equal(-95.0, recurring_transaction.expected_amount_min.to_f)
    assert_equal(-85.0, recurring_transaction.expected_amount_max.to_f)
    assert_equal(-89.99, recurring_transaction.expected_amount_avg.to_f)
  end

  test "round trips recurring transaction export semantics" do
    source_family = Family.create!(name: "Recurring Source", currency: "USD")
    source_account = source_family.accounts.create!(
      name: "Source Checking",
      accountable: Depository.new,
      balance: 1000,
      currency: "USD"
    )
    source_merchant = source_family.merchants.create!(name: "Internet Provider")

    source_family.recurring_transactions.create!(
      account: source_account,
      merchant: source_merchant,
      amount: -89.99,
      currency: "USD",
      expected_day_of_month: 14,
      last_occurrence_date: Date.parse("2024-01-14"),
      next_expected_date: Date.parse("2024-02-14"),
      status: "active",
      occurrence_count: 6,
      manual: true,
      expected_amount_min: -95,
      expected_amount_max: -85,
      expected_amount_avg: -89.99
    )

    source_family.recurring_transactions.create!(
      name: "Quarterly Insurance",
      amount: 240,
      currency: "USD",
      expected_day_of_month: 28,
      last_occurrence_date: Date.parse("2024-01-28"),
      next_expected_date: Date.parse("2024-04-28"),
      status: "inactive",
      occurrence_count: 2,
      manual: false
    )

    ndjson = nil
    Zip::File.open_buffer(Family::DataExporter.new(source_family).generate_export) do |zip|
      ndjson = zip.read("all.ndjson")
    end

    assert_not_nil ndjson
    assert ndjson.include?('"type":"RecurringTransaction"')

    Family::DataImporter.new(@family, ndjson).import!

    assert_equal 2, @family.recurring_transactions.count

    restored_account = @family.accounts.find_by!(name: "Source Checking")
    restored_merchant = @family.merchants.find_by!(name: "Internet Provider")
    restored_provider = @family.recurring_transactions.find_by!(merchant: restored_merchant)

    assert_equal restored_account, restored_provider.account
    assert_equal(-89.99, restored_provider.amount.to_f)
    assert_equal "USD", restored_provider.currency
    assert_equal 14, restored_provider.expected_day_of_month
    assert_equal Date.parse("2024-01-14"), restored_provider.last_occurrence_date
    assert_equal Date.parse("2024-02-14"), restored_provider.next_expected_date
    assert_equal "active", restored_provider.status
    assert_equal 6, restored_provider.occurrence_count
    assert_equal true, restored_provider.manual
    assert_equal(-95.0, restored_provider.expected_amount_min.to_f)
    assert_equal(-85.0, restored_provider.expected_amount_max.to_f)
    assert_equal(-89.99, restored_provider.expected_amount_avg.to_f)

    restored_named = @family.recurring_transactions.find_by!(name: "Quarterly Insurance")
    assert_nil restored_named.account
    assert_nil restored_named.merchant
    assert_equal 240.0, restored_named.amount.to_f
    assert_equal 28, restored_named.expected_day_of_month
    assert_equal Date.parse("2024-01-28"), restored_named.last_occurrence_date
    assert_equal Date.parse("2024-04-28"), restored_named.next_expected_date
    assert_equal "inactive", restored_named.status
    assert_equal 2, restored_named.occurrence_count
    assert_equal false, restored_named.manual
  end

  test "imports recurring transactions with unknown status fallback" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "acct-1",
          name: "Main Checking",
          balance: "5000",
          currency: "USD",
          accountable_type: "Depository"
        }
      },
      {
        type: "Merchant",
        data: {
          id: "merchant-1",
          name: "Streaming Service"
        }
      },
      {
        type: "RecurringTransaction",
        data: {
          id: "recurring-1",
          account_id: "acct-1",
          merchant_id: "merchant-1",
          amount: "-15.99",
          currency: "USD",
          expected_day_of_month: "8",
          last_occurrence_date: "2024-01-08",
          next_expected_date: "2024-02-08",
          status: "paused",
          occurrence_count: 2
        }
      }
    ])

    Family::DataImporter.new(@family, ndjson).import!

    recurring_transaction = @family.recurring_transactions.first
    assert_not_nil recurring_transaction
    assert_equal 8, recurring_transaction.expected_day_of_month
    assert_equal Date.parse("2024-01-08"), recurring_transaction.last_occurrence_date
    assert_equal Date.parse("2024-02-08"), recurring_transaction.next_expected_date
    assert_equal "active", recurring_transaction.status
  end

  test "skips recurring transactions with missing recurrence dates" do
    ndjson = build_ndjson([
      {
        type: "RecurringTransaction",
        data: {
          id: "recurring-1",
          amount: "-15.99",
          currency: "USD",
          expected_day_of_month: "8",
          last_occurrence_date: nil,
          status: "active",
          occurrence_count: 2,
          name: "Streaming Service"
        }
      }
    ])

    Family::DataImporter.new(@family, ndjson).import!

    assert_equal 0, @family.recurring_transactions.count
  end

  test "skips recurring transactions when referenced account is missing" do
    ndjson = build_ndjson([
      {
        type: "RecurringTransaction",
        data: {
          id: "recurring-1",
          account_id: "missing-account",
          amount: "-89.99",
          currency: "USD",
          expected_day_of_month: 14,
          last_occurrence_date: "2024-01-14",
          next_expected_date: "2024-02-14",
          status: "active",
          name: "Internet Provider"
        }
      }
    ])

    Family::DataImporter.new(@family, ndjson).import!

    assert_equal 0, @family.recurring_transactions.count
  end

  test "skips recurring transactions with blank expected day" do
    ndjson = build_ndjson([
      {
        type: "RecurringTransaction",
        data: {
          id: "recurring-1",
          amount: "-89.99",
          currency: "USD",
          expected_day_of_month: "",
          status: "active",
          name: "Internet Provider"
        }
      }
    ])

    Family::DataImporter.new(@family, ndjson).import!

    assert_equal 0, @family.recurring_transactions.count
  end

  test "imports transactions with references" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "acct-1",
          name: "Main Account",
          balance: "5000",
          currency: "USD",
          accountable_type: "Depository"
        }
      },
      {
        type: "Category",
        data: {
          id: "cat-1",
          name: "Food",
          color: "#FF0000",
          classification: "expense"
        }
      },
      {
        type: "Tag",
        data: {
          id: "tag-1",
          name: "Essential"
        }
      },
      {
        type: "Transaction",
        data: {
          id: "txn-1",
          account_id: "acct-1",
          date: "2024-01-15",
          amount: "-50.00",
          name: "Grocery Store",
          currency: "USD",
          category_id: "cat-1",
          tag_ids: [ "tag-1" ],
          notes: "Weekly groceries"
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    result = importer.import!

    assert_equal 1, result[:entries].count

    transaction = @family.transactions.first
    assert_not_nil transaction
    assert_equal "Grocery Store", transaction.entry.name
    assert_equal -50.0, transaction.entry.amount.to_f
    assert_equal "Food", transaction.category.name
    assert_equal 1, transaction.tags.count
    assert_equal "Essential", transaction.tags.first.name
    assert_equal "Weekly groceries", transaction.entry.notes
  end

  test "imports native split lines and lets transfers reference split children" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "checking",
          name: "Checking",
          balance: "1000",
          currency: "USD",
          accountable_type: "Depository"
        }
      },
      {
        type: "Account",
        data: {
          id: "wallet",
          name: "Wallet",
          balance: "500",
          currency: "USD",
          accountable_type: "Depository"
        }
      },
      {
        type: "Category",
        data: {
          id: "cat-fee",
          name: "Bank Fees",
          color: "#FF0000",
          classification: "expense"
        }
      },
      {
        type: "Tag",
        data: {
          id: "tag-imported",
          name: "Imported"
        }
      },
      {
        type: "Transaction",
        data: {
          id: "split-parent",
          account_id: "checking",
          date: "2024-01-15",
          amount: "104.00",
          name: "ATM withdrawal plus fee",
          currency: "USD",
          tag_ids: [ "tag-imported" ],
          split_lines: [
            {
              id: "split-transfer-leg",
              amount: "100.00",
              name: "Cash movement",
              notes: "Transfer portion"
            },
            {
              id: "split-fee-line",
              amount: "4.00",
              name: "ATM fee",
              category_id: "cat-fee",
              notes: "Fee portion"
            }
          ]
        }
      },
      {
        type: "Transaction",
        data: {
          id: "wallet-inflow",
          account_id: "wallet",
          date: "2024-01-15",
          amount: "-100.00",
          name: "Cash received",
          currency: "USD"
        }
      },
      {
        type: "Transfer",
        data: {
          id: "transfer-1",
          inflow_transaction_id: "wallet-inflow",
          outflow_transaction_id: "split-transfer-leg",
          status: "confirmed",
          notes: "Split-linked transfer"
        }
      }
    ])

    result = Family::DataImporter.new(@family, ndjson).import!

    parent_entry = @family.entries.find_by!(name: "ATM withdrawal plus fee")
    assert parent_entry.split_parent?
    assert_equal true, parent_entry.excluded
    assert_equal 4, result[:entries].count
    assert_includes result[:entries].map(&:id), parent_entry.id

    transfer_child = parent_entry.child_entries.find_by!(name: "Cash movement")
    fee_child = parent_entry.child_entries.find_by!(name: "ATM fee")
    assert_equal "Transfer portion", transfer_child.notes
    assert_equal "Fee portion", fee_child.notes
    assert_equal "Bank Fees", fee_child.transaction.category.name
    assert_equal [ "Imported" ], transfer_child.transaction.tags.map(&:name)
    assert_equal [ "Imported" ], fee_child.transaction.tags.map(&:name)

    transfer = Transfer.find_by!(notes: "Split-linked transfer")
    assert_equal "confirmed", transfer.status
    assert_equal "Cash movement", transfer.outflow_transaction.entry.name
    assert_equal "Cash received", transfer.inflow_transaction.entry.name
  end

  test "imports split lines without adding omitted parent taxonomy to explicit empty values" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "checking",
          name: "Checking",
          balance: "1000",
          currency: "USD",
          accountable_type: "Depository"
        }
      },
      {
        type: "Tag",
        data: {
          id: "tag-parent",
          name: "Parent tag"
        }
      },
      {
        type: "Merchant",
        data: {
          id: "merchant-parent",
          name: "Parent merchant"
        }
      },
      {
        type: "Transaction",
        data: {
          id: "split-parent",
          account_id: "checking",
          date: "2024-01-15",
          amount: "100.00",
          name: "Tagged merchant split",
          currency: "USD",
          merchant_id: "merchant-parent",
          tag_ids: [ "tag-parent" ],
          split_lines: [
            {
              id: "split-inherits",
              amount: "40.00",
              name: "Inherits omitted taxonomy"
            },
            {
              id: "split-empty",
              amount: "60.00",
              name: "Explicit empty taxonomy",
              merchant_id: nil,
              tag_ids: []
            }
          ]
        }
      }
    ])

    Family::DataImporter.new(@family, ndjson).import!

    parent_entry = @family.entries.find_by!(name: "Tagged merchant split")
    inherited_child = parent_entry.child_entries.find_by!(name: "Inherits omitted taxonomy")
    explicit_empty_child = parent_entry.child_entries.find_by!(name: "Explicit empty taxonomy")

    assert_equal "Parent merchant", inherited_child.transaction.merchant.name
    assert_equal [ "Parent tag" ], inherited_child.transaction.tags.map(&:name)
    assert_nil explicit_empty_child.transaction.merchant
    assert_empty explicit_empty_child.transaction.tags
  end

  test "session transaction reimport only replaces current family taggings" do
    session = @family.import_sessions.create!(expected_chunks: 1)
    account = @family.accounts.create!(
      name: "Session Checking",
      accountable: Depository.new,
      balance: 100,
      currency: "USD"
    )
    original_tag = @family.tags.create!(name: "Original")
    replacement_tag = @family.tags.create!(name: "Replacement")
    entry = account.entries.create!(
      date: Date.parse("2024-01-01"),
      amount: -10,
      currency: "USD",
      name: "Original transaction",
      source: "sure_import_session:#{session.id}",
      external_id: "Transaction:txn-1",
      entryable: Transaction.new(kind: "standard")
    )
    transaction = entry.entryable
    transaction.taggings.create!(tag: original_tag)

    other_family = Family.create!(name: "Other Family", currency: "USD")
    other_session = other_family.import_sessions.create!(expected_chunks: 1)
    other_account = other_family.accounts.create!(
      name: "Other Checking",
      accountable: Depository.new,
      balance: 100,
      currency: "USD"
    )
    other_tag = other_family.tags.create!(name: "Other Original")
    other_entry = other_account.entries.create!(
      date: Date.parse("2024-01-01"),
      amount: -10,
      currency: "USD",
      name: "Other transaction",
      source: "sure_import_session:#{other_session.id}",
      external_id: "Transaction:txn-1",
      entryable: Transaction.new(kind: "standard")
    )
    other_transaction = other_entry.entryable
    other_transaction.taggings.create!(tag: other_tag)

    other_session.source_mappings.create!(
      family: other_family,
      source_type: "Transaction",
      source_id: "txn-1",
      target: other_transaction
    )

    session.source_mappings.create!(
      family: @family,
      source_type: "Account",
      source_id: "acct-1",
      target: account
    )
    session.source_mappings.create!(
      family: @family,
      source_type: "Tag",
      source_id: "tag-1",
      target: replacement_tag
    )
    session.source_mappings.create!(
      family: @family,
      source_type: "Transaction",
      source_id: "txn-1",
      target: transaction
    )

    ndjson = build_ndjson([
      {
        type: "Transaction",
        data: {
          id: "txn-1",
          account_id: "acct-1",
          tag_ids: [ "tag-1" ],
          date: "2024-02-01",
          amount: "-12.34",
          currency: "USD",
          name: "Updated transaction"
        }
      }
    ])

    Family::DataImporter.new(@family, ndjson, import_session: session).import!

    assert_equal [ "Replacement" ], transaction.reload.tags.map(&:name)
    assert_equal "Updated transaction", entry.reload.name
    assert_equal [ "Other Original" ], other_transaction.reload.tags.map(&:name)
    assert_equal "Other transaction", other_entry.reload.name
  end

  test "imports trades with securities" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "inv-acct-1",
          name: "Investment Account",
          balance: "10000",
          currency: "USD",
          accountable_type: "Investment"
        }
      },
      {
        type: "Trade",
        data: {
          id: "trade-1",
          account_id: "inv-acct-1",
          date: "2024-01-15",
          ticker: "AAPL",
          qty: "10",
          price: "150.00",
          amount: "-1500.00",
          currency: "USD"
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    result = importer.import!

    # Account + Opening balance + Trade entry
    assert_equal 1, result[:entries].count

    trade = @family.trades.first
    assert_not_nil trade
    assert_equal "AAPL", trade.security.ticker
    assert_equal 10.0, trade.qty.to_f
    assert_equal 150.0, trade.price.to_f
  end

  test "imports holding snapshots with security identity" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "inv-acct-1",
          name: "Investment Account",
          balance: "10000",
          currency: "USD",
          accountable_type: "Investment"
        }
      },
      {
        type: "Holding",
        data: {
          id: "holding-1",
          account_id: "inv-acct-1",
          security_id: "security-1",
          ticker: "VTI",
          security_name: "Vanguard Total Stock Market ETF",
          exchange_operating_mic: "ARCX",
          country_code: "US",
          date: "2024-01-15",
          qty: "100",
          price: "250.25",
          amount: "25025.00",
          currency: "USD",
          cost_basis: "200.00",
          cost_basis_source: "manual",
          cost_basis_locked: true,
          security_locked: true
        }
      }
    ])

    Family::DataImporter.new(@family, ndjson).import!

    account = @family.accounts.find_by!(name: "Investment Account")
    holding = account.holdings.first

    assert_not_nil holding
    assert_equal Date.parse("2024-01-15"), holding.date
    assert_equal "VTI", holding.security.ticker
    assert_equal "Vanguard Total Stock Market ETF", holding.security.name
    assert_equal "ARCX", holding.security.exchange_operating_mic
    assert_equal 100.0, holding.qty.to_f
    assert_equal 250.25, holding.price.to_f
    assert_equal 25_025.0, holding.amount.to_f
    assert_equal 200.0, holding.cost_basis.to_f
    assert_equal "manual", holding.cost_basis_source
    assert holding.cost_basis_locked
    assert holding.security_locked

    opening_anchor = account.valuations.opening_anchor.first
    assert_equal Date.parse("2024-01-14"), opening_anchor.entry.date
  end

  test "imports duplicate holding snapshots idempotently by account security date and currency" do
    holding_record = {
      type: "Holding",
      data: {
        id: "holding-1",
        account_id: "inv-acct-1",
        security_id: "security-1",
        ticker: "VTI",
        security_name: "Vanguard Total Stock Market ETF",
        exchange_operating_mic: "ARCX",
        kind: "unsupported",
        date: "2024-01-15",
        qty: "100",
        price: "250.25",
        amount: "25025.00",
        currency: "USD"
      }
    }

    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "inv-acct-1",
          name: "Investment Account",
          balance: "10000",
          currency: "USD",
          accountable_type: "Investment"
        }
      },
      holding_record,
      holding_record.deep_merge(data: { id: "holding-1-duplicate", qty: "101", amount: "25275.25" })
    ])

    Family::DataImporter.new(@family, ndjson).import!

    account = @family.accounts.find_by!(name: "Investment Account")
    assert_equal 1, account.holdings.count

    holding = account.holdings.first
    assert_equal 101.0, holding.qty.to_f
    assert_equal 25_275.25, holding.amount.to_f
    assert_equal "standard", holding.security.kind
  end

  test "imports same holding date in different currencies separately" do
    holding_record = {
      type: "Holding",
      data: {
        id: "holding-1",
        account_id: "inv-acct-1",
        security_id: "security-1",
        ticker: "VTI",
        security_name: "Vanguard Total Stock Market ETF",
        exchange_operating_mic: "ARCX",
        date: "2024-01-15",
        qty: "100",
        price: "250.25",
        amount: "25025.00",
        currency: "USD"
      }
    }

    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "inv-acct-1",
          name: "Investment Account",
          balance: "10000",
          currency: "USD",
          accountable_type: "Investment"
        }
      },
      holding_record,
      holding_record.deep_merge(data: { id: "holding-2", currency: "CAD", amount: "34034.00" })
    ])

    Family::DataImporter.new(@family, ndjson).import!

    account = @family.accounts.find_by!(name: "Investment Account")
    assert_equal 2, account.holdings.count
    assert_equal %w[CAD USD], account.holdings.order(:currency).pluck(:currency)
  end

  test "round trips holding snapshots through full export" do
    source_family = Family.create!(
      name: "Source Family",
      currency: "USD",
      locale: "en",
      date_format: "%Y-%m-%d"
    )
    source_account = source_family.accounts.create!(
      name: "Round Trip Investment",
      accountable: Investment.new,
      balance: 25_000,
      currency: "USD"
    )
    source_security = Security.create!(
      ticker: "VTI#{SecureRandom.hex(4).upcase}",
      name: "Vanguard Total Stock Market ETF",
      country_code: "US",
      exchange_operating_mic: "ARCX"
    )
    source_account.holdings.create!(
      security: source_security,
      date: Date.parse("2024-01-15"),
      qty: 100,
      price: 250.25,
      amount: 25_025,
      currency: "USD",
      cost_basis: 200,
      cost_basis_source: "manual",
      cost_basis_locked: true,
      security_locked: true
    )

    zip_data = Family::DataExporter.new(source_family).generate_export
    ndjson = nil
    Zip::File.open_buffer(zip_data) do |zip|
      ndjson = zip.read("all.ndjson")
    end

    Family::DataImporter.new(@family, ndjson).import!

    imported_account = @family.accounts.find_by!(name: "Round Trip Investment")
    imported_holding = imported_account.holdings.find_by!(date: Date.parse("2024-01-15"))

    assert_equal source_security.ticker, imported_holding.security.ticker
    assert_equal "ARCX", imported_holding.security.exchange_operating_mic
    assert_equal 100.0, imported_holding.qty.to_f
    assert_equal 250.25, imported_holding.price.to_f
    assert_equal 25_025.0, imported_holding.amount.to_f
    assert_equal 200.0, imported_holding.cost_basis.to_f
    assert_equal "manual", imported_holding.cost_basis_source
    assert imported_holding.cost_basis_locked
    assert imported_holding.security_locked
  end

  test "round trips raw balance history through full export" do
    source_family = Family.create!(
      name: "Source Balance Family",
      currency: "USD",
      locale: "en",
      date_format: "%Y-%m-%d"
    )
    source_account = source_family.accounts.create!(
      name: "Round Trip Balance Checking",
      accountable: Depository.new,
      balance: 1_500,
      currency: "USD"
    )
    source_account.balances.create!(
      date: Date.parse("2024-01-31"),
      balance: 1_500,
      cash_balance: 1_450,
      currency: "USD",
      start_cash_balance: 1_000,
      start_non_cash_balance: 0,
      cash_inflows: 700,
      cash_outflows: 250,
      non_cash_inflows: 0,
      non_cash_outflows: 0,
      net_market_flows: 0,
      cash_adjustments: 0,
      non_cash_adjustments: 0,
      flows_factor: 1
    )

    zip_data = Family::DataExporter.new(source_family).generate_export
    ndjson = nil
    Zip::File.open_buffer(zip_data) do |zip|
      ndjson = zip.read("all.ndjson")
    end

    Family::DataImporter.new(@family, ndjson).import!

    imported_account = @family.accounts.find_by!(name: "Round Trip Balance Checking")
    imported_balance = imported_account.balances.find_by!(date: Date.parse("2024-01-31"), currency: "USD")

    assert_equal 1500.0, imported_balance.balance.to_f
    assert_equal 1450.0, imported_balance.cash_balance.to_f
    assert_equal 1000.0, imported_balance.start_cash_balance.to_f
    assert_equal 700.0, imported_balance.cash_inflows.to_f
    assert_equal 250.0, imported_balance.cash_outflows.to_f
  end

  test "imports holding snapshots with ticker fallback when exchange mic is missing" do
    existing_security = Security.create!(
      ticker: "VTI",
      name: "Existing VTI",
      exchange_operating_mic: "ARCX"
    )

    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "inv-acct-1",
          name: "Investment Account",
          balance: "10000",
          currency: "USD",
          accountable_type: "Investment"
        }
      },
      {
        type: "Holding",
        data: {
          id: "holding-1",
          account_id: "inv-acct-1",
          ticker: "VTI",
          security_name: "Imported VTI",
          date: "2024-01-15",
          qty: "100",
          price: "250.25",
          amount: "25025.00",
          currency: "USD",
          cost_basis_locked: false,
          security_locked: false
        }
      }
    ])

    Family::DataImporter.new(@family, ndjson).import!

    holding = @family.accounts.find_by!(name: "Investment Account").holdings.first
    assert_equal existing_security, holding.security
    assert_equal 1, Security.where(ticker: "VTI").count
  end

  test "updates cached security with safe holding metadata" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "inv-acct-1",
          name: "Investment Account",
          balance: "10000",
          currency: "USD",
          accountable_type: "Investment"
        }
      },
      {
        type: "Trade",
        data: {
          id: "trade-1",
          account_id: "inv-acct-1",
          security_id: "security-1",
          ticker: "VTI",
          date: "2024-01-10",
          qty: "10",
          price: "250.00",
          amount: "-2500.00",
          currency: "USD"
        }
      },
      {
        type: "Holding",
        data: {
          id: "holding-1",
          account_id: "inv-acct-1",
          security_id: "security-1",
          ticker: "VTI",
          security_name: "Vanguard Total Stock Market ETF",
          exchange_operating_mic: "ARCX",
          country_code: "US",
          website_url: "https://investor.vanguard.com",
          date: "2024-01-15",
          qty: "100",
          price: "250.25",
          amount: "25025.00",
          currency: "USD",
          cost_basis_locked: false,
          security_locked: false
        }
      }
    ])

    Family::DataImporter.new(@family, ndjson).import!

    security = @family.holdings.first.security
    assert_equal "Vanguard Total Stock Market ETF", security.name
    assert_equal "ARCX", security.exchange_operating_mic
    assert_equal "US", security.country_code
    assert_equal "https://investor.vanguard.com", security.website_url
  end

  test "imports valuations" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "prop-acct-1",
          name: "Property",
          balance: "500000",
          currency: "USD",
          accountable_type: "Property"
        }
      },
      {
        type: "Valuation",
        data: {
          id: "val-1",
          account_id: "prop-acct-1",
          date: "2024-06-15",
          amount: "520000",
          name: "Updated valuation",
          currency: "USD"
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    result = importer.import!

    assert_equal 1, result[:entries].count

    account = @family.accounts.find_by(name: "Property")
    valuation = account.valuations.joins(:entry).find_by(entries: { name: "Updated valuation" })
    assert_not_nil valuation
    assert_equal 520000.0, valuation.entry.amount.to_f
  end

  test "imports unknown valuation kinds as reconciliations" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "prop-acct-1",
          name: "Property",
          balance: "500000",
          currency: "USD",
          accountable_type: "Property"
        }
      },
      {
        type: "Valuation",
        data: {
          id: "val-1",
          account_id: "prop-acct-1",
          date: "2024-06-15",
          amount: "520000",
          name: "Updated valuation",
          currency: "USD",
          kind: "legacy_unknown_kind"
        }
      }
    ])

    Family::DataImporter.new(@family, ndjson).import!

    account = @family.accounts.find_by!(name: "Property")
    valuation = account.valuations.joins(:entry).find_by!(entries: { name: "Updated valuation" })
    assert_equal "reconciliation", valuation.kind
  end

  test "imports transfer decisions and rejected transfers with remapped transactions" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "checking",
          name: "Checking",
          balance: "1000",
          currency: "USD",
          accountable_type: "Depository"
        }
      },
      {
        type: "Account",
        data: {
          id: "savings",
          name: "Savings",
          balance: "2500",
          currency: "USD",
          accountable_type: "Depository"
        }
      },
      {
        type: "Transaction",
        data: {
          id: "transfer-outflow",
          account_id: "checking",
          date: "2024-01-15",
          amount: "100.00",
          name: "Transfer to savings",
          currency: "USD",
          kind: "standard"
        }
      },
      {
        type: "Transaction",
        data: {
          id: "transfer-inflow",
          account_id: "savings",
          date: "2024-01-15",
          amount: "-100.00",
          name: "Transfer from checking",
          currency: "USD",
          kind: "standard"
        }
      },
      {
        type: "Transfer",
        data: {
          id: "transfer-1",
          inflow_transaction_id: "transfer-inflow",
          outflow_transaction_id: "transfer-outflow",
          status: "confirmed",
          notes: "Confirmed by user"
        }
      },
      {
        type: "Transaction",
        data: {
          id: "rejected-outflow",
          account_id: "checking",
          date: "2024-01-20",
          amount: "25.00",
          name: "Candidate outflow",
          currency: "USD",
          kind: "standard"
        }
      },
      {
        type: "Transaction",
        data: {
          id: "rejected-inflow",
          account_id: "savings",
          date: "2024-01-20",
          amount: "-25.00",
          name: "Candidate inflow",
          currency: "USD",
          kind: "standard"
        }
      },
      {
        type: "RejectedTransfer",
        data: {
          id: "rejected-transfer-1",
          inflow_transaction_id: "rejected-inflow",
          outflow_transaction_id: "rejected-outflow"
        }
      }
    ])

    Family::DataImporter.new(@family, ndjson).import!

    transfer = Transfer.find_by!(notes: "Confirmed by user")
    assert_not_nil transfer
    assert_equal "confirmed", transfer.status
    assert_equal "Confirmed by user", transfer.notes
    assert_equal "Transfer from checking", transfer.inflow_transaction.entry.name
    assert_equal "Transfer to savings", transfer.outflow_transaction.entry.name
    assert_equal "funds_movement", transfer.inflow_transaction.kind
    assert_equal "funds_movement", transfer.outflow_transaction.kind

    rejected_transfer = RejectedTransfer
      .joins(inflow_transaction: :entry)
      .find_by!(entries: { name: "Candidate inflow" })
    assert_not_nil rejected_transfer
    assert_equal "Candidate inflow", rejected_transfer.inflow_transaction.entry.name
    assert_equal "Candidate outflow", rejected_transfer.outflow_transaction.entry.name
  end

  test "imports duplicate transfer decisions idempotently with unknown status fallback" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "checking",
          name: "Checking",
          balance: "1000",
          currency: "USD",
          accountable_type: "Depository"
        }
      },
      {
        type: "Account",
        data: {
          id: "savings",
          name: "Savings",
          balance: "2500",
          currency: "USD",
          accountable_type: "Depository"
        }
      },
      {
        type: "Transaction",
        data: {
          id: "transfer-outflow",
          account_id: "checking",
          date: "2024-01-15",
          amount: "100.00",
          name: "Transfer to savings",
          currency: "USD",
          kind: "funds_movement"
        }
      },
      {
        type: "Transaction",
        data: {
          id: "transfer-inflow",
          account_id: "savings",
          date: "2024-01-15",
          amount: "-100.00",
          name: "Transfer from checking",
          currency: "USD",
          kind: "funds_movement"
        }
      },
      {
        type: "Transfer",
        data: {
          id: "transfer-1",
          inflow_transaction_id: "transfer-inflow",
          outflow_transaction_id: "transfer-outflow",
          status: "settled"
        }
      },
      {
        type: "Transfer",
        data: {
          id: "transfer-1-duplicate",
          inflow_transaction_id: "transfer-inflow",
          outflow_transaction_id: "transfer-outflow",
          status: "settled"
        }
      }
    ])

    fallback_logs = []

    Rails.logger.stubs(:debug).with do |*args|
      message = args.first
      fallback_logs << message if message.to_s.include?("Unknown transfer status")
      true
    end

    assert_difference("Transfer.count", 1) do
      Family::DataImporter.new(@family, ndjson).import!
    end

    assert_equal [ 'Unknown transfer status "settled"; defaulting to pending' ], fallback_logs

    imported_transfer = Transfer
      .joins(inflow_transaction: :entry)
      .find_by!(entries: { name: "Transfer from checking" })
    assert_equal "pending", imported_transfer.status
  end

  test "imports budgets" do
    ndjson = build_ndjson([
      {
        type: "Budget",
        data: {
          id: "budget-1",
          start_date: "2024-01-01",
          end_date: "2024-01-31",
          budgeted_spending: "3000.00",
          expected_income: "5000.00",
          currency: "USD"
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    importer.import!

    budget = @family.budgets.first
    assert_not_nil budget
    assert_equal Date.parse("2024-01-01"), budget.start_date
    assert_equal Date.parse("2024-01-31"), budget.end_date
    assert_equal 3000.0, budget.budgeted_spending.to_f
    assert_equal 5000.0, budget.expected_income.to_f
  end

  test "imports budget_categories" do
    ndjson = build_ndjson([
      {
        type: "Category",
        data: {
          id: "cat-groceries",
          name: "Groceries",
          color: "#00FF00",
          classification: "expense"
        }
      },
      {
        type: "Budget",
        data: {
          id: "budget-1",
          start_date: "2024-01-01",
          end_date: "2024-01-31",
          budgeted_spending: "3000.00",
          expected_income: "5000.00",
          currency: "USD"
        }
      },
      {
        type: "BudgetCategory",
        data: {
          id: "bc-1",
          budget_id: "budget-1",
          category_id: "cat-groceries",
          budgeted_spending: "500.00",
          currency: "USD"
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    importer.import!

    budget = @family.budgets.first
    budget_category = budget.budget_categories.first
    assert_not_nil budget_category
    assert_equal "Groceries", budget_category.category.name
    assert_equal 500.0, budget_category.budgeted_spending.to_f
  end

  test "imports rules with conditions and actions" do
    ndjson = build_ndjson([
      {
        type: "Rule",
        version: 1,
        data: {
          name: "Categorize Coffee",
          resource_type: "transaction",
          active: true,
          conditions: [
            {
              condition_type: "transaction_name",
              operator: "like",
              value: "starbucks"
            }
          ],
          actions: [
            {
              action_type: "set_transaction_category",
              value: "Coffee"
            }
          ]
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    importer.import!

    rule = @family.rules.find_by(name: "Categorize Coffee")
    assert_not_nil rule
    assert rule.active
    assert_equal "transaction", rule.resource_type

    assert_equal 1, rule.conditions.count
    condition = rule.conditions.first
    assert_equal "transaction_name", condition.condition_type
    assert_equal "like", condition.operator
    assert_equal "starbucks", condition.value

    assert_equal 1, rule.actions.count
    action = rule.actions.first
    assert_equal "set_transaction_category", action.action_type

    # Category should be created
    category = @family.categories.find_by(name: "Coffee")
    assert_not_nil category
    assert_equal category.id, action.value
  end

  test "session rule reimport only replaces current family conditions and actions" do
    rule = @family.rules.build(name: "Original Rule", resource_type: "transaction", active: true)
    rule.conditions.build(condition_type: "transaction_name", operator: "like", value: "old")
    rule.actions.build(action_type: "auto_categorize")
    rule.save!

    other_family = Family.create!(name: "Other Rules Family", currency: "USD")
    other_rule = other_family.rules.build(name: "Other Rule", resource_type: "transaction", active: true)
    other_rule.conditions.build(condition_type: "transaction_name", operator: "like", value: "other-old")
    other_rule.actions.build(action_type: "auto_categorize")
    other_rule.save!

    other_session = other_family.import_sessions.create!(expected_chunks: 1)
    other_session.source_mappings.create!(
      family: other_family,
      source_type: "Rule",
      source_id: "rule-1",
      target: other_rule
    )

    session = @family.import_sessions.create!(expected_chunks: 1)
    session.source_mappings.create!(
      family: @family,
      source_type: "Rule",
      source_id: "rule-1",
      target: rule
    )

    ndjson = build_ndjson([
      {
        type: "Rule",
        version: 1,
        data: {
          id: "rule-1",
          name: "Updated Rule",
          resource_type: "transaction",
          active: true,
          conditions: [
            { condition_type: "transaction_name", operator: "like", value: "new" }
          ],
          actions: [
            { action_type: "set_transaction_name", value: "Renamed" }
          ]
        }
      }
    ])

    Family::DataImporter.new(@family, ndjson, import_session: session).import!

    assert_equal [ "new" ], rule.reload.conditions.map(&:value)
    assert_equal [ "set_transaction_name" ], rule.actions.map(&:action_type)
    assert_equal [ "other-old" ], other_rule.reload.conditions.map(&:value)
    assert_equal [ "auto_categorize" ], other_rule.actions.map(&:action_type)
  end

  test "imports rules from normalized operand value refs" do
    ndjson = build_ndjson([
      {
        type: "Rule",
        version: 1,
        data: {
          name: "Map Merchant To Dining",
          resource_type: "transaction",
          active: true,
          conditions: [
            {
              condition_type: "transaction_merchant",
              operator: "=",
              value_ref: {
                type: "Merchant",
                id: "source-merchant-id",
                name: "Coffee Bar"
              }
            }
          ],
          actions: [
            {
              action_type: "set_transaction_category",
              value_ref: {
                type: "Category",
                id: "source-category-id",
                name: "Dining"
              }
            }
          ]
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    importer.import!

    rule = @family.rules.find_by!(name: "Map Merchant To Dining")
    merchant = @family.merchants.find_by!(name: "Coffee Bar")
    category = @family.categories.find_by!(name: "Dining")

    assert_equal merchant.id, rule.conditions.first.value
    assert_equal category.id, rule.actions.first.value
  end

  test "imports rule value refs when legacy operand values are stale UUIDs" do
    stale_merchant_id = SecureRandom.uuid
    stale_category_id = SecureRandom.uuid
    ndjson = build_ndjson([
      {
        type: "Rule",
        version: 1,
        data: {
          name: "Map Stale UUID Operands",
          resource_type: "transaction",
          active: true,
          conditions: [
            {
              condition_type: "transaction_merchant",
              operator: "=",
              value: stale_merchant_id,
              value_ref: {
                type: "Merchant",
                id: stale_merchant_id,
                name: "Coffee Bar"
              }
            }
          ],
          actions: [
            {
              action_type: "set_transaction_category",
              value: stale_category_id,
              value_ref: {
                type: "Category",
                id: stale_category_id,
                name: "Dining"
              }
            }
          ]
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    importer.import!

    rule = @family.rules.find_by!(name: "Map Stale UUID Operands")
    merchant = @family.merchants.find_by!(name: "Coffee Bar")
    category = @family.categories.find_by!(name: "Dining")

    assert_equal merchant.id, rule.conditions.first.value
    assert_equal category.id, rule.actions.first.value
    assert_not @family.merchants.exists?(name: stale_merchant_id)
    assert_not @family.categories.exists?(name: stale_category_id)
  end

  test "preserves explicit false rule operand values" do
    importer = Family::DataImporter.new(@family, "")

    value = importer.send(
      :rule_operand_value,
      {
        "value" => false,
        "value_ref" => {
          "type" => "Category",
          "name" => "Fallback"
        }
      }
    )

    assert_equal false, value
  end

  test "imports rules with compound conditions" do
    ndjson = build_ndjson([
      {
        type: "Rule",
        version: 1,
        data: {
          name: "Compound Rule",
          resource_type: "transaction",
          active: true,
          conditions: [
            {
              condition_type: "compound",
              operator: "or",
              sub_conditions: [
                {
                  condition_type: "transaction_name",
                  operator: "like",
                  value: "walmart"
                },
                {
                  condition_type: "transaction_name",
                  operator: "like",
                  value: "target"
                }
              ]
            }
          ],
          actions: [
            {
              action_type: "auto_categorize"
            }
          ]
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    importer.import!

    rule = @family.rules.find_by(name: "Compound Rule")
    assert_not_nil rule

    parent_condition = rule.conditions.first
    assert_equal "compound", parent_condition.condition_type
    assert_equal "or", parent_condition.operator
    assert_equal 2, parent_condition.sub_conditions.count
  end

  test "skips invalid records gracefully" do
    ndjson = "not valid json\n" + build_ndjson([
      {
        type: "Account",
        data: {
          id: "valid-acct",
          name: "Valid Account",
          balance: "1000",
          currency: "USD",
          accountable_type: "Depository"
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    result = importer.import!

    assert_equal 1, result[:accounts].count
    assert_equal "Valid Account", result[:accounts].first.name
  end

  test "skips unsupported record types" do
    ndjson = build_ndjson([
      {
        type: "UnsupportedType",
        data: { id: "unknown" }
      },
      {
        type: "Account",
        data: {
          id: "valid-acct",
          name: "Known Account",
          balance: "1000",
          currency: "USD",
          accountable_type: "Depository"
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    result = importer.import!

    assert_equal 1, result[:accounts].count
  end

  test "full import scenario with all entity types" do
    ndjson = build_ndjson([
      # Account
      {
        type: "Account",
        data: {
          id: "acct-main",
          name: "Main Checking",
          balance: "5000",
          currency: "USD",
          accountable_type: "Depository"
        }
      },
      # Category
      {
        type: "Category",
        data: {
          id: "cat-food",
          name: "Food",
          color: "#FF5733",
          classification: "expense"
        }
      },
      # Tag
      {
        type: "Tag",
        data: {
          id: "tag-weekly",
          name: "Weekly"
        }
      },
      # Merchant
      {
        type: "Merchant",
        data: {
          id: "merchant-1",
          name: "Local Grocery"
        }
      },
      # Transaction
      {
        type: "RecurringTransaction",
        data: {
          id: "recurring-grocery",
          account_id: "acct-main",
          merchant_id: "merchant-1",
          amount: "-75.50",
          currency: "USD",
          expected_day_of_month: 15,
          last_occurrence_date: "2024-01-15",
          next_expected_date: "2024-02-15",
          status: "active",
          occurrence_count: 3,
          manual: false
        }
      },
      # Transaction
      {
        type: "Transaction",
        data: {
          id: "txn-1",
          account_id: "acct-main",
          date: "2024-01-15",
          amount: "-75.50",
          name: "Weekly groceries",
          currency: "USD",
          category_id: "cat-food",
          merchant_id: "merchant-1",
          tag_ids: [ "tag-weekly" ]
        }
      },
      # Budget
      {
        type: "Budget",
        data: {
          id: "budget-jan",
          start_date: "2024-01-01",
          end_date: "2024-01-31",
          budgeted_spending: "2000",
          expected_income: "4000",
          currency: "USD"
        }
      },
      # BudgetCategory
      {
        type: "BudgetCategory",
        data: {
          id: "bc-food",
          budget_id: "budget-jan",
          category_id: "cat-food",
          budgeted_spending: "500",
          currency: "USD"
        }
      },
      # Rule
      {
        type: "Rule",
        version: 1,
        data: {
          name: "Auto-tag groceries",
          resource_type: "transaction",
          active: true,
          conditions: [
            { condition_type: "transaction_name", operator: "like", value: "grocery" }
          ],
          actions: [
            { action_type: "set_transaction_tags", value: "Weekly" }
          ]
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    result = importer.import!

    # Verify all entities were created
    assert_equal 1, result[:accounts].count
    assert_equal 1, @family.categories.count
    assert_equal 1, @family.tags.count
    assert_equal 1, @family.merchants.count
    assert_equal 1, @family.recurring_transactions.count
    assert_equal 1, @family.transactions.count
    assert_equal 1, @family.budgets.count
    assert_equal 1, @family.budget_categories.count
    assert_equal 1, @family.rules.count

    # Verify relationships
    transaction = @family.transactions.first
    assert_equal "Food", transaction.category.name
    assert_equal "Local Grocery", transaction.merchant.name
    assert_equal "Weekly", transaction.tags.first.name

    recurring_transaction = @family.recurring_transactions.first
    assert_equal "Main Checking", recurring_transaction.account.name
    assert_equal "Local Grocery", recurring_transaction.merchant.name
  end

  private

    def build_ndjson(records)
      records.map(&:to_json).join("\n")
    end
end
