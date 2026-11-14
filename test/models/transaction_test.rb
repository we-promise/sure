require "test_helper"

class TransactionTest < ActiveSupport::TestCase
  include EntriesTestHelper

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

  test "category_editable? is true for non-transfer kinds" do
    assert Transaction.new(kind: "standard").category_editable?
    assert Transaction.new(kind: "one_time").category_editable?
  end

  test "category_editable? without a Transfer record stays editable regardless of kind" do
    # An unmatched provider-imported leg has no counterpart to defer to and
    # no other way for the user to fix a provider mislabel, so it stays
    # editable just like a regular transaction.
    assert Transaction.new(kind: "loan_payment").category_editable?
    assert Transaction.new(kind: "investment_contribution").category_editable?
    assert Transaction.new(kind: "funds_movement").category_editable?
    assert Transaction.new(kind: "cc_payment").category_editable?
  end

  test "category_editable? keeps a matched transfer's category on its outflow leg" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500, kind: "investment_contribution")
    inflow_entry = create_transaction(date: Date.current, account: accounts(:investment), amount: -500, kind: "funds_movement")
    Transfer.create!(inflow_transaction: inflow_entry.transaction, outflow_transaction: outflow_entry.transaction)

    # Budgets count the outflow leg, so only that leg takes a category; the
    # inflow leg shows the outflow's category read-only instead of a picker
    # whose choice would never reach a budget.
    assert outflow_entry.transaction.reload.category_editable?
    assert_not outflow_entry.transaction.category_set_on_transfer_outflow?
    assert_not inflow_entry.transaction.reload.category_editable?
    assert inflow_entry.transaction.category_set_on_transfer_outflow?

    fm_outflow = create_transaction(date: Date.current, account: accounts(:depository), amount: 500, kind: "funds_movement")
    fm_inflow = create_transaction(date: Date.current, account: accounts(:connected), amount: -500, kind: "funds_movement")
    Transfer.create!(inflow_transaction: fm_inflow.transaction, outflow_transaction: fm_outflow.transaction)

    assert_not fm_outflow.transaction.reload.category_editable?
    assert_not fm_inflow.transaction.reload.category_editable?
    assert_not fm_inflow.transaction.category_set_on_transfer_outflow?
  end

  test "a matched inflow leg stays read-only after its kind is edited to standard" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500, kind: "investment_contribution")
    inflow_entry = create_transaction(date: Date.current, account: accounts(:investment), amount: -500, kind: "funds_movement")
    Transfer.create!(inflow_transaction: inflow_entry.transaction, outflow_transaction: outflow_entry.transaction)
    inflow_entry.transaction.update!(kind: "standard")

    assert inflow_entry.transaction.reload.category_set_on_transfer_outflow?
    assert_not inflow_entry.transaction.category_editable?
  end

  test "category_editable? stays true for the outflow leg even if a later sync leaves a stale funds_movement kind" do
    # Account::ProviderImportAdapter can reassign an already-matched
    # transaction's kind on a later sync without touching its Transfer.
    # Transfer#categorizable? is destination-account based (stable), so
    # delegating to it -- rather than reading this transaction's own kind
    # directly -- keeps category_editable? correct despite the stale kind.
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500, kind: "investment_contribution")
    inflow_entry = create_transaction(date: Date.current, account: accounts(:investment), amount: -500, kind: "funds_movement")
    Transfer.create!(inflow_transaction: inflow_entry.transaction, outflow_transaction: outflow_entry.transaction)
    outflow_entry.transaction.update_column(:kind, "funds_movement")

    assert outflow_entry.transaction.reload.category_editable?
  end

  test "payment? is true for cc_payment kind without a Transfer record" do
    assert Transaction.new(kind: "cc_payment").payment?
    assert_not Transaction.new(kind: "funds_movement").payment?
  end

  test "payment? defers to Transfer#payment? when a Transfer record exists" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500, kind: "cc_payment")
    inflow_entry = create_transaction(date: Date.current, account: accounts(:credit_card), amount: -500, kind: "cc_payment")
    Transfer.create!(inflow_transaction: inflow_entry.transaction, outflow_transaction: outflow_entry.transaction)

    assert outflow_entry.transaction.reload.payment?
    assert inflow_entry.transaction.reload.payment?
  end

  test "payment? stays false for a non-payment transfer even if a later sync leaves a stale cc_payment kind" do
    # Account::ProviderImportAdapter can reassign an already-matched
    # transaction's kind on a later sync without touching its Transfer
    # record. Simulate that here: a regular funds_movement transfer (to a
    # non-liability account) whose outflow transaction's kind was later
    # (incorrectly) left as "cc_payment".
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500, kind: "funds_movement")
    inflow_entry = create_transaction(date: Date.current, account: accounts(:connected), amount: -500, kind: "funds_movement")
    Transfer.create!(inflow_transaction: inflow_entry.transaction, outflow_transaction: outflow_entry.transaction)
    outflow_entry.transaction.update_column(:kind, "cc_payment")

    assert_not outflow_entry.transaction.reload.payment?
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

  test "reassign_category! updates category, touches entries, and returns the count" do
    transaction = transactions(:one)
    entry = entries(:transaction)
    new_category = categories(:income)

    before = entry.updated_at

    count = travel_to(1.minute.from_now) do
      Transaction.reassign_category!(Transaction.where(id: transaction.id), new_category.id)
    end

    assert_equal 1, count
    assert_equal new_category.id, transaction.reload.category_id
    assert entry.reload.updated_at > before
  end

  test "reassign_category! returns 0 for an empty scope" do
    assert_equal 0, Transaction.reassign_category!(Transaction.none, categories(:income).id)
  end

  test "toggle_tag! adds a missing tag and removes a present one" do
    transaction = transactions(:one)
    transaction.update!(tag_ids: [ tags(:one).id ])

    transaction.toggle_tag!(tags(:two))
    assert_equal [ tags(:one).id, tags(:two).id ].sort, transaction.tag_ids.sort

    transaction.toggle_tag!(tags(:one))
    assert_equal [ tags(:two).id ], transaction.reload.tag_ids
  end

  test "toggle_tag! keeps a tag added by a concurrent toggle" do
    transaction = transactions(:one)
    transaction.update!(tag_ids: [])
    stale_copy = Transaction.find(transaction.id)
    stale_copy.tag_ids # load the pre-toggle snapshot

    transaction.toggle_tag!(tags(:one))
    stale_copy.toggle_tag!(tags(:two))

    assert_equal [ tags(:one).id, tags(:two).id ].sort, transaction.reload.tag_ids.sort
  end

  test "name_suggestions_for ranks names and each name's category by frequency" do
    family = families(:dylan_family)
    account = accounts(:depository)
    # entries(:transaction) is named "Starbucks" and its transaction (transactions(:one)) is categorized as food_and_drink

    # "Starbucks" ends up more frequent than "Star Market", and within "Starbucks",
    # food_and_drink ends up more frequent than its one-off income-categorized occurrence.
    2.times { create_transaction(name: "Starbucks", account: account, category: categories(:food_and_drink)) }
    create_transaction(name: "Starbucks", account: account, category: categories(:income))
    create_transaction(name: "Star Market", account: account, category: categories(:income))

    suggestions = family.transactions.name_suggestions_for("star")

    assert_equal [ "Starbucks", "Star Market" ], suggestions.map(&:name)
    assert_equal categories(:food_and_drink), suggestions.first.category
    assert_equal categories(:income), suggestions.second.category
  end

  test "name_suggestions_for counts each transaction once when the caller scope joins account_shares" do
    # TransactionsController#name_suggestions calls this via
    # `family.transactions.merge(Account.accessible_by(user))`. Account.accessible_by does
    # left_joins(:account_shares), and for an account the user owns, its WHERE predicate
    # matches every joined share row regardless of which share it is — so an owned account
    # shared with multiple family members fans out to multiple rows per transaction. Without
    # counting distinct transaction ids, that inflates a name's frequency by however many
    # times its account is shared, letting a rarely-used name outrank a genuinely common one.
    family = families(:dylan_family)
    owner = users(:family_admin)
    shared_account = accounts(:depository) # owned by family_admin; already shared with family_member (fixture)
    unshared_account = accounts(:investment) # owned by family_admin; not shared with anyone

    2.times do |i|
      extra_member = User.create!(
        family: family, email: "extra_member_#{i}@example.com", password: "password123456",
        first_name: "Extra", last_name: "Member #{i}", role: "member"
      )
      AccountShare.create!(account: shared_account, user: extra_member, permission: "read_only", include_in_finances: true)
    end
    # shared_account now has 3 account_shares rows (1 fixture + 2 created above), so its
    # accessible_by join fans out 3x — a single real transaction would inflate to a count of 3.

    create_transaction(name: "Fanout Rare", account: shared_account, category: categories(:food_and_drink))
    2.times { create_transaction(name: "Fanout Common", account: unshared_account, category: categories(:income)) }

    suggestions = family.transactions
      .merge(Account.accessible_by(owner))
      .name_suggestions_for("Fanout")

    assert_equal [ "Fanout Common", "Fanout Rare" ], suggestions.map(&:name)
  end

  test "name_suggestions_for returns an empty array when the query is too short" do
    family = families(:dylan_family)
    assert_equal [], family.transactions.name_suggestions_for("st")
    assert_equal [], family.transactions.name_suggestions_for("  ")
  end

  test "name_suggestions_for returns an empty array when no past transaction matches" do
    family = families(:dylan_family)
    assert_equal [], family.transactions.name_suggestions_for("no such merchant")
  end

  test "name_suggestions_for caps results at 8" do
    family = families(:dylan_family)
    account = accounts(:depository)

    9.times { |i| create_transaction(name: "Merchant #{i}", account: account) }

    suggestions = family.transactions.name_suggestions_for("Merchant")

    assert_equal 8, suggestions.size
  end

  test "category_from finds categories still set by a given source" do
    family = families(:empty)
    account = family.accounts.create!(name: "Category from", balance: 0, currency: "USD", accountable: Depository.new)
    coffee = family.categories.create!(name: "Coffee")
    tea = family.categories.create!(name: "Tea")
    ai_guess = create_transaction(account: account, name: "Guess").transaction
    ai_guess.enrich_attribute(:category_id, coffee.id, source: "ai", metadata: { confidence: 0.9 })
    changed = create_transaction(account: account, name: "Changed").transaction
    changed.enrich_attribute(:category_id, coffee.id, source: "ai")
    changed.update!(category: tea)
    scope = family.transactions

    assert_equal [ ai_guess.id ], scope.category_from("ai").pluck(:id)
    assert_equal [ ai_guess.id ], scope.category_from("bayes", "ai").pluck(:id)
    assert_empty scope.category_from("bayes").pluck(:id)
    assert_empty scope.category_from("ai", since: 1.minute.from_now).pluck(:id)
    assert_equal [ ai_guess.id ], scope.category_from("ai", metadata: { confidence: 0.9 }).pluck(:id)
    assert_empty scope.category_from("ai", metadata: { confidence: 0.5 }).pluck(:id)
  end


  test "a category changed away from the AI's and back again is no longer the AI's" do
    transaction = transactions(:one)
    transaction.enrich_attribute(:category_id, categories(:income).id, source: "ai")
    assert Transaction.where(id: transaction.id).category_from("ai").exists?, "precondition: the AI's category"

    transaction.update!(category: categories(:food_and_drink))
    transaction.update!(category: categories(:income))

    assert_not Transaction.where(id: transaction.id).category_from("ai").exists?
  end

  test "an automatic categorizer's own change keeps its claim" do
    transaction = transactions(:one)
    transaction.enrich_attribute(:category_id, categories(:income).id, source: "ai")
    transaction.enrich_attribute(:category_id, categories(:food_and_drink).id, source: "bayes", metadata: { locked_by_bayes: true })

    assert Transaction.where(id: transaction.id).category_from("bayes", metadata: { locked_by_bayes: true }).exists?
  end

  test "an automatic categorizer setting its category again reclaims it" do
    transaction = transactions(:one)
    transaction.enrich_attribute(:category_id, categories(:income).id, source: "ai")
    transaction.update!(category: categories(:food_and_drink))
    transaction.enrich_attribute(:category_id, categories(:income).id, source: "ai")

    assert Transaction.where(id: transaction.id).category_from("ai").exists?
  end

  test "a category changed away from the AI's and back again stays in the AI history" do
    transaction = transactions(:one)
    transaction.enrich_attribute(:category_id, categories(:income).id, source: "ai")
    transaction.update!(category: categories(:food_and_drink))
    transaction.update!(category: categories(:income))
    family = transaction.entry.account.family

    assert_includes Transaction::Search.new(family, filters: { ai_status: [ "history" ] }).transactions_scope.ids, transaction.id
    assert_not_includes Transaction::Search.new(family, filters: { ai_status: [ "current" ] }).transactions_scope.ids, transaction.id
  end

  test "clearing the AI cache keeps a lock on a category the user changed away from and back" do
    transaction = transactions(:one)
    transaction.enrich_attribute(:category_id, categories(:income).id, source: "ai")
    transaction.lock_attr!(:category_id)
    transaction.update!(category: categories(:food_and_drink))
    transaction.update!(category: categories(:income))

    transaction.reload.clear_ai_cache

    assert transaction.reload.locked?(:category_id)
  end

  test "a category merge ends a claim the AI recorded on the category merged into" do
    transaction = transactions(:one)
    transaction.enrich_attribute(:category_id, categories(:income).id, source: "ai")
    # A claim recorded before category changes ended claims: the category moved on without it.
    transaction.update_column(:category_id, categories(:food_and_drink).id)

    Transaction.reassign_category!(Transaction.where(id: transaction.id), categories(:income).id)

    assert_equal categories(:income), transaction.reload.category
    assert_not Transaction.where(id: transaction.id).category_from("ai").exists?
  end

  test "clearing the AI cache locks the transaction before its enrichments" do
    transaction = transactions(:one)
    transaction.enrich_attribute(:category_id, categories(:income).id, source: "ai")
    transaction.update!(category: categories(:food_and_drink))
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }

    begin
      transaction.reload.clear_ai_cache
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
    lock_at = statements.index { |sql| sql.match?(/FROM "transactions".*FOR UPDATE/m) }
    delete_at = statements.index { |sql| sql.match?(/DELETE FROM "data_enrichments"/) }
    assert lock_at, "locks the transaction"
    assert delete_at, "deletes the AI's enrichments"
    assert_operator lock_at, :<, delete_at
  end

  test "clearing the AI cache of a transaction deleted since it was loaded clears nothing" do
    transaction = transactions(:one)
    transaction.enrich_attribute(:category_id, categories(:income).id, source: "ai")
    stale = Transaction.find(transaction.id)
    Transaction.where(id: transaction.id).delete_all

    assert_equal 0, stale.clear_ai_cache
  end

  test "clearing Bayes' locks keeps a lock on a category the user changed away from and back" do
    transaction = transactions(:one)
    transaction.enrich_attribute(:category_id, categories(:income).id, source: "bayes", metadata: { locked_by_bayes: true })
    transaction.lock_attr!(:category_id)

    transaction.update!(category: categories(:food_and_drink))
    transaction.update!(category: categories(:income))
    transaction.lock_attr!(:category_id)
    transaction.entry.account.family.clear_bayes_locks!

    assert transaction.reload.locked?(:category_id)
  end

  test "a leg that becomes a plain transfer loses the Investment Contributions category" do
    transaction = contribution_leg(accounts(:depository))

    transaction.update!(kind: "funds_movement")

    assert_nil transaction.reload.category
  end

  # A rule of the user's set it before the leg became a plain transfer; the
  # same rule run afterwards would set it again, so it stays.
  test "a leg that becomes a plain transfer keeps the Investment Contributions category a rule set" do
    transaction = contribution_leg(accounts(:depository))
    transaction.update_columns(category_id: nil)
    transaction.reload.enrich_attribute(:category_id, accounts(:depository).family.investment_contributions_category.id, source: "rule")

    transaction.update!(kind: "funds_movement")

    assert_equal accounts(:depository).family.investment_contributions_category, transaction.reload.category
  end

  test "a plain transfer leg keeps a category the user locked, set in the same save, or another category" do
    family = families(:dylan_family)
    locked = contribution_leg(accounts(:depository))
    locked.lock_attr!(:category_id)
    same_save = contribution_leg(accounts(:depository))
    same_save.update_columns(category_id: categories(:income).id)
    other = contribution_leg(accounts(:depository))
    other.update!(category: categories(:income))

    locked.update!(kind: "funds_movement")
    same_save.update!(kind: "funds_movement", category: family.investment_contributions_category)
    other.update!(kind: "funds_movement")

    assert_equal family.investment_contributions_category, locked.reload.category
    assert_equal family.investment_contributions_category, same_save.reload.category
    assert_equal categories(:income), other.reload.category
  end

  # A sync or confirmation holding an older copy of the leg must not clear a
  # category the user set on it in the meantime.
  test "a leg becoming a plain transfer keeps a category set after its copy was loaded" do
    transaction = contribution_leg(accounts(:depository))
    stale_copy = Transaction.find(transaction.id)
    stale_copy.category
    transaction.update!(category: categories(:income))

    stale_copy.update!(kind: "funds_movement")

    assert_equal categories(:income), transaction.reload.category
    assert_equal "funds_movement", transaction.kind
  end

  test "drop_stale_contribution_categories! clears unlocked stale legs and touches their entries" do
    stale = contribution_leg(accounts(:depository))
    stale.update_columns(kind: "funds_movement")
    locked = contribution_leg(accounts(:depository))
    locked.update_columns(kind: "funds_movement")
    locked.lock_attr!(:category_id)
    stale.entry.update_columns(updated_at: 1.day.ago)
    locked.entry.update_columns(updated_at: 1.day.ago)

    assert_equal 1, Transaction.drop_stale_contribution_categories!

    assert_nil stale.reload.category_id
    assert_in_delta Time.current, stale.entry.reload.updated_at, 5.seconds
    assert_not_nil locked.reload.category_id
    assert_operator locked.entry.reload.updated_at, :<, 1.hour.ago
  end

  # The AI locks every category it assigns, and Bayes does with lock_results;
  # neither lock is the user's choice. A category the user chose after the AI
  # is theirs, lock and all.
  test "a leg that becomes a plain transfer loses an Investment Contributions category an automatic categorizer locked" do
    category = families(:dylan_family).investment_contributions_category
    by_ai = auto_locked_leg(accounts(:depository), category, "ai")
    by_bayes = auto_locked_leg(accounts(:depository), category, "bayes", metadata: { locked_by_bayes: true })
    by_user = auto_locked_leg(accounts(:depository), categories(:income), "ai")
    by_user.update!(category: category)
    by_user.lock_attr!(:category_id)

    [ by_ai, by_bayes, by_user ].each { |leg| leg.reload.update!(kind: "funds_movement") }

    assert_nil by_ai.reload.category_id
    assert_nil by_bayes.reload.category_id
    assert_equal category, by_user.reload.category
  end

  test "clearing an automatic categorizer's category drops its lock and claim with it" do
    category = families(:dylan_family).investment_contributions_category
    by_ai = auto_locked_leg(accounts(:depository), category, "ai")
    by_bayes = auto_locked_leg(accounts(:depository), category, "bayes", metadata: { locked_by_bayes: true })

    [ by_ai, by_bayes ].each { |leg| leg.reload.update!(kind: "funds_movement") }

    [ by_ai, by_bayes ].each do |leg|
      leg.reload
      assert_nil leg.category_id
      assert_not leg.locked?(:category_id), "categorizers would skip the leg if it became a plain transaction again"
    end
    assert_not by_ai.data_enrichments.exists?(attribute_name: "category_id", source: "ai")
    assert_not by_bayes.data_enrichments.find_by!(attribute_name: "category_id", source: "bayes").metadata.key?("locked_by_bayes")
  end

  test "a copy loaded before a categorizer set the category still has it cleared" do
    leg = accounts(:depository).entries.create!(
      name: "To broker", amount: 100, date: Date.current, currency: "USD",
      entryable: Transaction.new(kind: "investment_contribution")
    ).transaction
    loaded_earlier = Transaction.find(leg.id)
    leg.enrich_attribute(:category_id, families(:dylan_family).investment_contributions_category.id, source: "ai")
    leg.lock_attr!(:category_id)

    loaded_earlier.update!(kind: "funds_movement")

    assert_nil leg.reload.category_id
    assert_nil loaded_earlier.category_id
    assert_not loaded_earlier.locked?(:category_id)
  end

  test "with_stale_contribution_category counts an automatic categorizer's lock as no lock" do
    category = families(:dylan_family).investment_contributions_category
    by_ai = auto_locked_leg(accounts(:depository), category, "ai")
    by_user = contribution_leg(accounts(:depository))
    by_user.lock_attr!(:category_id)
    [ by_ai, by_user ].each { |leg| leg.update_columns(kind: "funds_movement") }

    found = Transaction.where(id: [ by_ai.id, by_user.id ]).with_stale_contribution_category

    assert_equal [ by_ai.id ], found.pluck(:id)
  end

  test "with_stale_contribution_category finds unlocked plain transfer legs with the category" do
    stale = contribution_leg(accounts(:depository))
    stale.update_columns(kind: "funds_movement")
    locked = contribution_leg(accounts(:depository))
    locked.update_columns(kind: "funds_movement")
    locked.lock_attr!(:category_id)
    contribution = contribution_leg(accounts(:depository))

    found = Transaction.with_stale_contribution_category

    assert_includes found, stale
    assert_not_includes found, locked
    assert_not_includes found, contribution
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

    # A contribution leg whose category an automatic categorizer assigned and
    # locked, as Family::AutoCategorizer and Bayes with lock_results do.
    def auto_locked_leg(account, category, source, metadata: {})
      leg = account.entries.create!(
        name: "To broker", amount: 100, date: Date.current, currency: "USD",
        entryable: Transaction.new(kind: "investment_contribution")
      ).transaction
      leg.enrich_attribute(:category_id, category.id, source: source, metadata: metadata)
      leg.lock_attr!(:category_id)
      leg
    end

    def contribution_leg(account)
      account.entries.create!(
        name: "To broker", amount: 100, date: Date.current, currency: "USD",
        entryable: Transaction.new(kind: "investment_contribution", category: account.family.investment_contributions_category)
      ).transaction
    end
end
