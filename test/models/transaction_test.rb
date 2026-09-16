require "test_helper"

class TransactionTest < ActiveSupport::TestCase
  include EntriesTestHelper

  test "existing_manual_recurring_transaction finds a match by merchant" do
    family = families(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new
    merchant = family.merchants.create! name: "Test Merchant"
    entry = create_transaction(account: account, amount: 100, merchant: merchant)
    transaction = entry.entryable

    recurring = family.recurring_transactions.create!(
      account: account,
      merchant: merchant,
      amount: entry.amount,
      currency: entry.currency,
      expected_day_of_month: entry.date.day,
      last_occurrence_date: entry.date,
      next_expected_date: 1.month.from_now,
      status: "active",
      manual: true,
      occurrence_count: 1
    )

    assert_equal recurring, transaction.existing_manual_recurring_transaction
  end

  test "existing_manual_recurring_transaction finds a match by name when no merchant" do
    family = families(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new
    entry = create_transaction(account: account, amount: 50, name: "Netflix")
    transaction = entry.entryable

    recurring = family.recurring_transactions.create!(
      account: account,
      name: "Netflix",
      amount: entry.amount,
      currency: entry.currency,
      expected_day_of_month: entry.date.day,
      last_occurrence_date: entry.date,
      next_expected_date: 1.month.from_now,
      status: "active",
      manual: true,
      occurrence_count: 1
    )

    assert_equal recurring, transaction.existing_manual_recurring_transaction
  end

  test "existing_manual_recurring_transaction returns nil when no manual recurring transaction matches" do
    family = families(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new
    other_account = family.accounts.create! name: "Other", balance: 0, currency: "USD", accountable: Depository.new
    merchant = family.merchants.create! name: "Test Merchant"
    other_merchant = family.merchants.create! name: "Other Merchant"
    entry = create_transaction(account: account, amount: 100, merchant: merchant)
    transaction = entry.entryable

    base_attrs = {
      expected_day_of_month: entry.date.day,
      last_occurrence_date: entry.date,
      next_expected_date: 1.month.from_now,
      status: "active",
      occurrence_count: 1
    }

    # Differs by account
    family.recurring_transactions.create!(base_attrs.merge(
      account: other_account, merchant: merchant, amount: entry.amount, currency: entry.currency, manual: true
    ))
    # Differs by merchant
    family.recurring_transactions.create!(base_attrs.merge(
      account: account, merchant: other_merchant, amount: entry.amount, currency: entry.currency, manual: true
    ))
    # Differs by amount
    family.recurring_transactions.create!(base_attrs.merge(
      account: account, merchant: merchant, amount: entry.amount + 1, currency: entry.currency, manual: true
    ))
    # Differs by currency
    family.recurring_transactions.create!(base_attrs.merge(
      account: account, merchant: merchant, amount: entry.amount, currency: "EUR", manual: true
    ))
    # Differs by manual flag
    family.recurring_transactions.create!(base_attrs.merge(
      account: account, merchant: merchant, amount: entry.amount, currency: entry.currency, manual: false
    ))

    assert_nil transaction.existing_manual_recurring_transaction
  end

  test "pending? is true when extra.simplefin.pending is truthy" do
    transaction = Transaction.new(extra: { "simplefin" => { "pending" => true } })

    assert transaction.pending?
  end

  test "pending? is true when extra.plaid.pending is truthy" do
    transaction = Transaction.new(extra: { "plaid" => { "pending" => "true" } })

    assert transaction.pending?
  end

  test "pending? is true when extra.lunchflow.pending is truthy" do
    transaction = Transaction.new(extra: { "lunchflow" => { "pending" => true } })

    assert transaction.pending?
  end

  test "pending? is false when no provider pending metadata is present" do
    transaction = Transaction.new(extra: { "plaid" => { "pending" => false } })

    assert_not transaction.pending?
  end

  test "pending? returns true for enable_banking pending transactions" do
    transaction = Transaction.new(extra: { "enable_banking" => { "pending" => true } })

    assert transaction.pending?
  end

  test "pending? returns false for enable_banking non-pending transactions" do
    transaction = Transaction.new(extra: { "enable_banking" => { "pending" => false } })

    assert_not transaction.pending?
  end

  # The SQL forms of "is this pending?" must give the answer pending? gives for
  # whatever is stored. PostgreSQL's ::boolean reads "no", "False", "Off" and
  # " false" as false where ActiveModel::Type::Boolean reads them as true.
  test "every SQL pending predicate agrees with pending? on any stored flag" do
    account = families(:empty).accounts.create! name: "Pending parity", balance: 0, currency: "USD", accountable: Depository.new

    [ true, false, nil, "true", "false", "no", "False", "Off", " false", "", "0", "1", "t", "f", 1, 0, 0.0 ].each do |flag|
      transaction = create_transaction(account: account, amount: 10).entryable
      transaction.update!(extra: { "plaid" => { "pending" => flag } })

      sql_pending_answers(transaction).each do |form, answer|
        assert_equal transaction.pending?, answer, "#{form} disagrees with pending? on #{flag.inspect}"
      end
    end
  end

  # ::boolean raises PG::InvalidTextRepresentation on a value it cannot parse,
  # which aborts the whole query -- an income statement, a balance sync -- not
  # just the one row.
  test "no SQL pending predicate raises on a flag PostgreSQL cannot cast" do
    account = families(:empty).accounts.create! name: "Pending parity", balance: 0, currency: "USD", accountable: Depository.new
    transaction = create_transaction(account: account, amount: 10).entryable
    transaction.update!(extra: { "simplefin" => { "pending" => "maybe" } })

    assert transaction.pending?
    sql_pending_answers(transaction).each do |form, answer|
      assert answer, "#{form} should call a \"maybe\" flag pending, as pending? does"
    end
  end

  test "SQL false values stay in sync with ActiveModel boolean casting" do
    expected_false_values = Set.new(ActiveModel::Type::Boolean::FALSE_VALUES.grep(String)).add("")

    assert_equal expected_false_values, Transaction::PENDING_FLAG_FALSE_VALUES.to_set
  end

  # pending_sql and PENDING_CHECK_SQL share one connection-free literal list;
  # it must quote exactly as the database adapter would.
  test "the shared SQL false-value list matches the adapter's quoting" do
    adapter_quoted = Transaction::PENDING_FLAG_FALSE_VALUES.map { |value| Transaction.connection.quote(value) }.join(", ")

    assert_equal adapter_quoted, Transaction::PENDING_FLAG_FALSE_VALUES_SQL
    assert_includes Transaction.pending_sql, "NOT IN (#{adapter_quoted})"
    assert_includes Transaction::PENDING_CHECK_SQL, "NOT IN (#{adapter_quoted})"
  end

  test "provider-specific SQL only considers the requested pending namespaces" do
    account = families(:empty).accounts.create! name: "Provider pending scope", balance: 0,
      currency: "USD", accountable: Depository.new
    akahu_pending = create_transaction(account: account, amount: 10).entryable
    akahu_pending.update!(extra: { "akahu" => { "pending" => "maybe" } })
    akahu_false = create_transaction(account: account, amount: 11).entryable
    akahu_false.update!(extra: { "akahu" => { "pending" => "off" } })
    other_provider = create_transaction(account: account, amount: 12).entryable
    other_provider.update!(extra: { "simplefin" => { "pending" => true } })

    matches = Transaction.where(Transaction.pending_sql("transactions", providers: [ :akahu ]))

    assert_equal [ akahu_pending.id ], matches.pluck(:id)
    assert_equal [ akahu_pending.id ], Transaction.where(
      Transaction.pending_sql("transactions", providers: [ "akahu", "unsupported" ])
    ).pluck(:id)
    assert_empty Transaction.where(Transaction.pending_sql("transactions", providers: [])).pluck(:id)
  end

  # Narrowed to some providers, the SQL is the same rule applied to those
  # providers' flags only: another provider's flag must not leak in.
  test "pending_sql for a provider subset agrees with pending? on that provider's flag alone" do
    account = families(:empty).accounts.create! name: "Pending subset", balance: 0, currency: "USD", accountable: Depository.new

    [ true, false, nil, "true", "false", "no", "False", "Off", " false", "", "0", "1", "t", "f", "maybe", 1, 0 ].each do |flag|
      transaction = create_transaction(account: account, amount: 10).entryable
      transaction.update!(extra: { "up" => { "pending" => flag }, "plaid" => { "pending" => true } })
      expected = Transaction.new(extra: { "up" => { "pending" => flag } }).pending?

      assert_equal expected, Transaction.where(Transaction.pending_sql(providers: %w[up])).exists?(transaction.id),
        "pending_sql(providers: up) disagrees with pending? on #{flag.inspect}"
      assert_equal !expected, Transaction.where(Transaction.not_pending_sql(providers: %w[up])).exists?(transaction.id),
        "not_pending_sql(providers: up) disagrees with pending? on #{flag.inspect}"
    end
  end

  test "pending SQL quotes the table alias and JSON keys" do
    connection = ActiveRecord::Base.connection
    table_alias = "pending alias"
    sql = Transaction.pending_sql(table_alias)

    assert_includes sql, "#{connection.quote_table_name(table_alias)}.extra"
    assert_includes sql, "-> #{connection.quote(Transaction::PENDING_PROVIDERS.first)} ->> #{connection.quote('pending')}"
    false_values = Transaction::PENDING_FLAG_FALSE_VALUES.map { |value| connection.quote(value) }.join(", ")
    assert_includes sql, "NOT IN (#{false_values})"
    assert_not_includes sql, "#{table_alias}.extra"
  end

  # A provider key holding something other than an object says nothing about
  # that provider, and must not stop another provider's flag from counting.
  # SQL reads NULL for it and moves on; pending? used to raise inside
  # Hash#dig and rescue the whole row to false.
  test "malformed metadata under one provider does not hide another provider's flag" do
    account = families(:empty).accounts.create! name: "Pending parity", balance: 0, currency: "USD", accountable: Depository.new

    [ "bad", [ "pending" ], 1 ].each do |malformed|
      transaction = create_transaction(account: account, amount: 10).entryable
      transaction.update!(extra: { "simplefin" => malformed, "plaid" => { "pending" => true } })

      assert transaction.pending?, "pending? should see plaid's flag past simplefin => #{malformed.inspect}"
      sql_pending_answers(transaction).each do |form, answer|
        assert answer, "#{form} should see plaid's flag past simplefin => #{malformed.inspect}"
      end
    end
  end

  test "pending_duplicate_candidates offers only transactions pending? calls posted" do
    account = families(:empty).accounts.create! name: "Merge", balance: 0, currency: "USD", accountable: Depository.new
    pending_entry = create_transaction(account: account, amount: 10)
    pending_entry.entryable.update!(extra: { "plaid" => { "pending" => true } })

    posted = create_transaction(account: account, amount: 10)
    create_transaction(account: account, amount: 10).entryable.update!(extra: { "plaid" => { "pending" => "no" } })
    create_transaction(account: account, amount: 10).entryable.update!(extra: { "plaid" => { "pending" => "maybe" } })

    assert_equal [ posted.id ], pending_entry.entryable.pending_duplicate_candidates.map(&:id)
  end

  test "investment_contribution is a valid kind" do
    transaction = Transaction.new(kind: "investment_contribution")

    assert_equal "investment_contribution", transaction.kind
    assert transaction.investment_contribution?
  end

  test "TRANSFER_KINDS constant matches transfer? method" do
    Transaction::TRANSFER_KINDS.each do |kind|
      assert Transaction.new(kind: kind).transfer?, "#{kind} should be a transfer kind"
    end

    non_transfer_kinds = Transaction.kinds.keys - Transaction::TRANSFER_KINDS
    non_transfer_kinds.each do |kind|
      assert_not Transaction.new(kind: kind).transfer?, "#{kind} should NOT be a transfer kind"
    end
  end

  test "all transaction kinds are valid" do
    valid_kinds = %w[standard funds_movement cc_payment loan_payment one_time investment_contribution]

    valid_kinds.each do |kind|
      transaction = Transaction.new(kind: kind)
      assert_equal kind, transaction.kind, "#{kind} should be a valid transaction kind"
    end
  end

  test "ACTIVITY_LABELS contains all valid labels" do
    assert_includes Transaction::ACTIVITY_LABELS, "Buy"
    assert_includes Transaction::ACTIVITY_LABELS, "Sell"
    assert_includes Transaction::ACTIVITY_LABELS, "Sweep In"
    assert_includes Transaction::ACTIVITY_LABELS, "Sweep Out"
    assert_includes Transaction::ACTIVITY_LABELS, "Dividend"
    assert_includes Transaction::ACTIVITY_LABELS, "Reinvestment"
    assert_includes Transaction::ACTIVITY_LABELS, "Interest"
    assert_includes Transaction::ACTIVITY_LABELS, "Fee"
    assert_includes Transaction::ACTIVITY_LABELS, "Transfer"
    assert_includes Transaction::ACTIVITY_LABELS, "Contribution"
    assert_includes Transaction::ACTIVITY_LABELS, "Withdrawal"
    assert_includes Transaction::ACTIVITY_LABELS, "Exchange"
    assert_includes Transaction::ACTIVITY_LABELS, "Other"
  end

  test "exchange_rate getter returns nil when extra is nil" do
    transaction = Transaction.new
    assert_nil transaction.exchange_rate
  end

  test "exchange_rate setter stores normalized numeric value" do
    transaction = Transaction.new
    transaction.exchange_rate = "1.5"

    assert_equal 1.5, transaction.exchange_rate
  end

  test "exchange_rate setter marks invalid input" do
    transaction = Transaction.new
    transaction.exchange_rate = "not a number"

    assert_equal "not a number", transaction.extra["exchange_rate"]
    assert transaction.extra["exchange_rate_invalid"]
  end

  test "exchange_rate setter rejects non-finite input" do
    transaction = Transaction.new
    transaction.exchange_rate = "Infinity"

    assert_equal "Infinity", transaction.extra["exchange_rate"]
    assert transaction.extra["exchange_rate_invalid"]
  end

  test "exchange_rate setter clears invalid flag for valid input" do
    transaction = Transaction.new
    transaction.exchange_rate = "not a number"
    transaction.exchange_rate = "1.5"

    assert_equal 1.5, transaction.exchange_rate
    assert_equal false, transaction.extra["exchange_rate_invalid"]
  end

  test "exchange_rate validation rejects non-numeric input" do
    transaction = Transaction.new(
      category: categories(:income),
      extra: { "exchange_rate" => "invalid" }
    )
    transaction.exchange_rate = "not a number"

    assert_not transaction.valid?
    assert_includes transaction.errors[:exchange_rate], "must be a number"
  end

  test "exchange_rate validation rejects zero values" do
    transaction = Transaction.new(
      category: categories(:income)
    )
    transaction.exchange_rate = 0

    assert_not transaction.valid?
    assert_includes transaction.errors[:exchange_rate], "must be greater than 0"
  end

  test "exchange_rate validation rejects negative values" do
    transaction = Transaction.new(
      category: categories(:income)
    )
    transaction.exchange_rate = -1.5

    assert_not transaction.valid?
    assert_includes transaction.errors[:exchange_rate], "must be greater than 0"
  end

  test "exchange_rate validation allows positive values" do
    transaction = Transaction.new(
      category: categories(:income)
    )
    transaction.exchange_rate = 1.5

    assert transaction.valid?
  end

  test "activity_security returns the referenced security from extra metadata" do
    security = securities(:aapl)
    transaction = Transaction.new(extra: { "security_id" => security.id })

    assert_equal security, transaction.activity_security
  end

  test "activity_security returns nil when no security metadata is present" do
    transaction = Transaction.new(extra: {})

    assert_nil transaction.activity_security
  end

  test "activity_security refreshes when security metadata changes on the same instance" do
    transaction = Transaction.new(extra: { "security_id" => securities(:aapl).id })

    assert_equal securities(:aapl), transaction.activity_security

    transaction.extra["security_id"] = securities(:msft).id

    assert_equal securities(:msft), transaction.activity_security
  end

  test "record_category_usage! touches the new category's last_used_at" do
    transaction = transactions(:one)
    category = categories(:income)
    assert_nil category.last_used_at

    transaction.update!(category: category)
    transaction.record_category_usage!

    assert_not_nil category.reload.last_used_at
  end

  test "record_category_usage! does nothing when category_id did not change" do
    transaction = transactions(:one)
    category = transaction.category
    assert_nil category.last_used_at

    transaction.reload
    transaction.record_category_usage!

    assert_nil category.reload.last_used_at
  end

  test "record_category_usage! does nothing when category is cleared" do
    transaction = transactions(:one)

    transaction.update!(category: nil)

    assert_nothing_raised { transaction.record_category_usage! }
  end

  test "record_category_usage! is not invoked by rule-driven category enrichment" do
    transaction = transactions(:one)
    category = categories(:income)
    assert_nil category.last_used_at

    transaction.enrich_attribute(:category_id, category.id, source: "rule")

    assert_nil category.reload.last_used_at
  end

  private
    # Whether each SQL form of "is this transaction pending?" says it is.
    def sql_pending_answers(transaction)
      entry_id = transaction.entry.id
      posted_row = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([
          "SELECT 1 FROM transactions t WHERE t.id = ? #{Transaction.pending_providers_sql("t")}", transaction.id
        ])
      )

      {
        "Transaction.pending" => Transaction.pending.exists?(transaction.id),
        "Transaction.excluding_pending" => !Transaction.excluding_pending.exists?(transaction.id),
        "Entry.pending" => Entry.pending.exists?(entry_id),
        "Entry.excluding_pending (pending_check_sql)" => !Entry.excluding_pending.exists?(entry_id),
        "Transaction.pending_providers_sql" => posted_row.nil?
      }
    end
end
