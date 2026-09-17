require "test_helper"

# Each test here demonstrates one row of the flow contract in
# docs/portfolio/methodology.md (P1-P19); config/portfolio_contract_tests.yml
# binds the row to the test name and portfolio:verify_contract_coverage
# fails when they drift apart. Rename a test and the gate says which row lost
# its evidence.
class Portfolio::FlowClassifierTest < ActiveSupport::TestCase
  include PortfolioFlowTestHelper

  setup do
    @family = families(:empty)
    @brokerage = create_portfolio_account(@family, name: "Brokerage")
    @ira = create_portfolio_account(@family, name: "IRA")
    @checking = @family.accounts.create!(name: "Checking", balance: 5000, currency: "USD", accountable: Depository.new)

    @family_scope = Portfolio::FlowClassifier.new(scope_account_ids: [ @brokerage.id, @ira.id ])
    @brokerage_scope = Portfolio::FlowClassifier.new(scope_account_ids: [ @brokerage.id ])
  end

  test "a Dividend income trade is income" do
    entry = create_income_trade(account: @brokerage, label: "Dividend", amount: 50)

    assert_equal :income, @family_scope.classify(entry)
    assert_equal :income, @brokerage_scope.classify(entry)
  end

  test "a Dividend transaction carrying the security id in extra is income" do
    flat = create_income_transaction(account: @brokerage, label: "Dividend", amount: 12.5, extra_shape: :flat)
    nested = create_income_transaction(account: @brokerage, label: "Dividend", amount: 7, extra_shape: :nested)
    bare = create_income_transaction(account: @brokerage, label: "Dividend", amount: 3, extra_shape: :none)

    assert_equal :income, @family_scope.classify(flat)
    assert_equal :income, @family_scope.classify(nested)
    assert_equal :income, @family_scope.classify(bare)
  end

  test "a Plaid-shaped zero-amount Dividend trade is income" do
    entry = create_plaid_dividend_trade(account: @brokerage)

    assert_equal 0, entry.amount
    assert_equal :income, @family_scope.classify(entry),
      "the cash is invisible (amount 0) but the entry is still income, not a deposit"
  end

  test "Interest is income whether stored as a trade or a transaction" do
    trade = create_income_trade(account: @brokerage, label: "Interest", amount: 4)
    transaction = create_income_transaction(account: @brokerage, label: "Interest", amount: 4, extra_shape: :none)

    assert_equal :income, @family_scope.classify(trade)
    assert_equal :income, @family_scope.classify(transaction)
  end

  test "a Fee label is a fee whether stored as a trade or a transaction" do
    trade = create_portfolio_trade(account: @brokerage, qty: 0, price: 0, fee: 0, label: "Fee")
    trade.update!(amount: 9.95)
    transaction = create_labelled_transaction(account: @brokerage, label: "Fee", amount: 1.5)

    assert_equal :fee, @family_scope.classify(trade)
    assert_equal :fee, @family_scope.classify(transaction)
  end

  test "the fee leg of a linked transfer is a fee" do
    transfer = create_linked_transfer(family: @family, from: @checking, to: @brokerage, amount: 500, source_fee_amount: 2)
    fee_entry = transfer.fee_transactions.first.entry

    assert_equal "standard", fee_entry.entryable.kind
    assert_nil fee_entry.entryable.investment_activity_label
    assert_equal :fee, Portfolio::FlowClassifier.new(scope_account_ids: [ @checking.id ]).classify(fee_entry)
  end

  test "Buy, Sell and Reinvestment trades are internal" do
    buy = create_portfolio_trade(account: @brokerage, qty: 10, price: 100)
    sell = create_portfolio_trade(account: @brokerage, qty: -4, price: 110)
    reinvestment = create_portfolio_trade(account: @brokerage, qty: 1, price: 50, label: "Reinvestment")

    assert_equal :internal, @family_scope.classify(buy)
    assert_equal :internal, @family_scope.classify(sell)
    assert_equal :internal, @family_scope.classify(reinvestment),
      "reinvested dividends are only income when a separate Dividend entry records them"
    assert_equal :internal, @brokerage_scope.classify(buy)
  end

  test "Sweep In, Sweep Out and Exchange are internal at both scopes" do
    [ "Sweep In", "Sweep Out", "Exchange" ].each do |label|
      trade = create_portfolio_trade(account: @brokerage, qty: 5, price: 1, label: label)
      transaction = create_labelled_transaction(account: @brokerage, label: label, amount: -5)

      assert_equal :internal, @family_scope.classify(trade), "#{label} trade"
      assert_equal :internal, @brokerage_scope.classify(transaction), "#{label} transaction"
    end
  end

  test "Contribution and Withdrawal labels are external in the direction of the money" do
    deposit = create_labelled_transaction(account: @brokerage, label: "Contribution", amount: -1000)
    withdrawal = create_labelled_transaction(account: @brokerage, label: "Withdrawal", amount: 250)
    # Kraken's ledger writes these with kind funds_movement and no Transfer
    # row; the label still decides.
    kraken_deposit = create_labelled_transaction(account: @brokerage, label: "Contribution", amount: -300, kind: "funds_movement")

    assert_equal :external_inflow, @family_scope.classify(deposit)
    assert_equal :external_outflow, @family_scope.classify(withdrawal)
    assert_equal :external_inflow, @family_scope.classify(kraken_deposit)
  end

  test "a linked transfer is internal at family scope and external at account scope" do
    transfer = create_linked_transfer(family: @family, from: @brokerage, to: @ira, amount: 400)
    outflow = transfer.outflow_transaction.entry
    inflow = transfer.inflow_transaction.entry

    assert_equal "funds_movement", transfer.outflow_transaction.kind

    assert_equal :internal, @family_scope.classify(outflow)
    assert_equal :internal, @family_scope.classify(inflow)

    assert_equal :external_outflow, @brokerage_scope.classify(outflow)
    assert_equal :external_inflow, Portfolio::FlowClassifier.new(scope_account_ids: [ @ira.id ]).classify(inflow)
  end

  test "an investment contribution from outside the scope is an external inflow" do
    transfer = create_linked_transfer(family: @family, from: @checking, to: @brokerage, amount: 1000)
    inflow = transfer.inflow_transaction.entry
    outflow = transfer.outflow_transaction.entry

    assert_equal "investment_contribution", transfer.outflow_transaction.kind
    assert_equal :external_inflow, @family_scope.classify(inflow)
    assert_equal :external_inflow, @brokerage_scope.classify(inflow)

    # Seen from a scope that contains both accounts, the same pair is internal.
    household = Portfolio::FlowClassifier.new(scope_account_ids: [ @checking.id, @brokerage.id ])
    assert_equal :internal, household.classify(inflow)
    assert_equal :internal, household.classify(outflow)
  end

  test "a transfer-kind transaction with no linked counterpart is external by sign" do
    unlinked_in = create_labelled_transaction(account: @brokerage, label: nil, amount: -800, kind: "funds_movement")
    unlinked_out = create_labelled_transaction(account: @brokerage, label: nil, amount: 200, kind: "investment_contribution")

    assert_equal :external_inflow, @family_scope.classify(unlinked_in)
    assert_equal :external_outflow, @family_scope.classify(unlinked_out)
  end

  test "a security transfer is internal only when its opposite leg is in scope" do
    security = create_portfolio_security
    out_leg, in_leg = create_security_transfer(security: security, from: @brokerage, to: @ira, qty: 10, price: 50)

    assert_equal :internal, @family_scope.classify(out_leg)
    assert_equal :internal, @family_scope.classify(in_leg)

    assert_equal :external_outflow, @brokerage_scope.classify(out_leg)
    assert_equal :external_inflow, Portfolio::FlowClassifier.new(scope_account_ids: [ @ira.id ]).classify(in_leg)

    # A Transfer trade with no opposite leg anywhere (position moved in from
    # a broker that is not tracked) is external even at family scope.
    orphan = create_portfolio_trade(account: @brokerage, security: create_portfolio_security, qty: 3, price: 20, label: "Transfer")
    assert_equal :external_inflow, @family_scope.classify(orphan)
  end

  test "an unlabelled or Other trade is internal" do
    unlabelled = create_portfolio_trade(account: @brokerage, qty: 2, price: 10, label: nil)
    unlabelled.entryable.update!(investment_activity_label: nil)
    other = create_portfolio_trade(account: @brokerage, qty: -2, price: 10, label: "Other")

    assert_nil unlabelled.entryable.reload.investment_activity_label
    assert_equal :internal, @family_scope.classify(unlabelled)
    assert_equal :internal, @family_scope.classify(other)
  end

  test "an unlabelled standard transaction is external by sign" do
    deposit = create_labelled_transaction(account: @brokerage, label: nil, amount: -150)
    withdrawal = create_labelled_transaction(account: @brokerage, label: "Other", amount: 75)

    assert_equal :external_inflow, @family_scope.classify(deposit)
    assert_equal :external_outflow, @family_scope.classify(withdrawal)
  end

  test "a pending flag that is not a boolean is read the same way by both forms" do
    # ActiveModel::Type::Boolean is the Ruby definition, so anything present
    # that is not one of its false values is pending. The SQL form used to
    # cast with ::boolean, which disagrees ('no' is false to PostgreSQL and
    # true to ActiveModel) and raises on anything it cannot parse.
    shapes = { "no" => nil, "maybe" => nil, "true" => nil, "false" => :income, "0" => :income, "" => :income }

    shapes.each do |flag, expected|
      entry = create_labelled_transaction(account: @brokerage, label: "Dividend", amount: -10, extra: { "plaid" => { "pending" => flag } })

      assert_equal expected, @family_scope.classify(entry.reload), "Ruby, pending=#{flag.inspect}"
      assert_equal expected, @family_scope.classify_ids([ entry.id ])[entry.id], "SQL, pending=#{flag.inspect}"
    end
  end

  test "excluded entries, pending transactions and valuations are not classified" do
    excluded = create_portfolio_trade(account: @brokerage, qty: 1, price: 10, excluded: true)
    pending = create_labelled_transaction(account: @brokerage, label: "Dividend", amount: -10, extra: { "simplefin" => { "pending" => true } })
    valuation = @brokerage.entries.create!(name: "Valuation", date: Date.current, amount: 1000, currency: "USD", entryable: Valuation.new(kind: "reconciliation"))

    assert_nil @family_scope.classify(excluded)
    assert_nil @family_scope.classify(pending)
    assert_nil @family_scope.classify(valuation)
  end

  test "direction follows the trade quantity sign or the transaction amount sign" do
    inflow_trade = create_portfolio_trade(account: @brokerage, qty: 5, price: 10, label: "Contribution")
    outflow_trade = create_portfolio_trade(account: @brokerage, qty: -5, price: 10, label: "Withdrawal")
    inflow_transaction = create_labelled_transaction(account: @brokerage, label: "Withdrawal", amount: -20)

    assert_equal :external_inflow, @family_scope.classify(inflow_trade)
    assert_equal :external_outflow, @family_scope.classify(outflow_trade)
    # The label says withdrawal but money came in: the sign wins, so a
    # mislabelled row cannot flip the direction of a return.
    assert_equal :external_inflow, @family_scope.classify(inflow_transaction)
  end

  test "every activity label has a rule" do
    assert_equal Transaction::ACTIVITY_LABELS.sort, Portfolio::FlowClassifier::LABEL_RULES.keys.sort
    assert_equal Trade::ACTIVITY_LABELS.sort, Portfolio::FlowClassifier::LABEL_RULES.keys.sort
    assert_includes Portfolio::FlowClassifier.labels_for(:income), "Dividend"
    assert_equal %w[Fee], Portfolio::FlowClassifier.labels_for(:fee)
  end

  test "scope_account_ids is required" do
    assert_raises(ArgumentError) { Portfolio::FlowClassifier.new }
  end

  test "the SQL form agrees with the Ruby form on every corpus entry at both scopes" do
    corpus = build_corpus

    [ @family_scope, @brokerage_scope, Portfolio::FlowClassifier.new(scope_account_ids: [ @checking.id, @brokerage.id ]) ].each do |classifier|
      ruby = corpus.to_h { |entry| [ entry.id, classifier.classify(entry.reload) ] }
      sql = classifier.classify_ids(corpus.map(&:id))

      assert_equal corpus.size, sql.size
      ruby.each do |id, ruby_class|
        entry = corpus.find { |e| e.id == id }
        # assert_nil / assert_equal split so a nil expectation does not trip
        # Minitest's deprecation of assert_equal nil.
        message =
          "scope #{classifier.scope_account_ids.size} accounts: #{entry.name} (#{entry.entryable_type}, #{entry.entryable.try(:investment_activity_label).inspect}, kind #{entry.entryable.try(:kind).inspect})"
        if ruby_class.nil?
          assert_nil sql.fetch(id), message
        else
          assert_equal ruby_class, sql.fetch(id), message
        end
      end
    end

    assert_equal Portfolio::FlowClassifier::CLASSES.sort, @family_scope.classify_ids(corpus.map(&:id)).values.compact.uniq.sort,
      "the corpus must exercise every class"
  end

  test "the SQL form only binds the scope ids and never interpolates entry data" do
    sql = @family_scope.sql_case

    assert_includes sql, "ARRAY['#{@brokerage.id}','#{@ira.id}']::uuid[]"
    Portfolio::FlowClassifier::LABEL_RULES.keys.each do |label|
      next if label == "Other"
      assert_includes sql, "'#{label}'"
    end
    assert_no_match(/#\{/, sql)

    # Finished SQL, not a template. If any `:name` survived here, handing the
    # CASE to sanitize_sql_array (as an earlier version did) would read it as
    # a bind variable and raise before the query ran -- which is what a label
    # carrying a colon used to do. `::` casts are not placeholders.
    placeholders = sql.gsub("::", "").scan(/:[a-zA-Z]\w*/)
    assert_empty placeholders, "sql_case must be final SQL, not a bind template"
  end

  private
    # One entry per contract row plus the shapes each provider writes, at
    # every position the classifier branches on.
    def build_corpus
      security = create_portfolio_security
      entries = []
      entries << create_income_trade(account: @brokerage, label: "Dividend", amount: 50)
      entries << create_income_transaction(account: @brokerage, label: "Dividend", amount: 12, extra_shape: :flat)
      entries << create_income_transaction(account: @ira, label: "Dividend", amount: 12, extra_shape: :nested)
      entries << create_plaid_dividend_trade(account: @brokerage)
      entries << create_income_trade(account: @brokerage, label: "Interest", amount: 4)
      entries << create_income_transaction(account: @brokerage, label: "Interest", amount: 4, extra_shape: :none)
      entries << create_portfolio_trade(account: @brokerage, qty: 0, price: 0, label: "Fee").tap { |e| e.update!(amount: 9.95) }
      entries << create_labelled_transaction(account: @brokerage, label: "Fee", amount: 1.5)
      entries << create_portfolio_trade(account: @brokerage, qty: 10, price: 100, fee: 5)
      entries << create_portfolio_trade(account: @brokerage, qty: -4, price: 110, fee: 5, fee_in_amount: false)
      entries << create_portfolio_trade(account: @ira, qty: 1, price: 50, label: "Reinvestment")
      [ "Sweep In", "Sweep Out", "Exchange" ].each do |label|
        entries << create_portfolio_trade(account: @brokerage, qty: 5, price: 1, label: label)
        entries << create_labelled_transaction(account: @ira, label: label, amount: -5)
      end
      entries << create_labelled_transaction(account: @brokerage, label: "Contribution", amount: -1000)
      entries << create_labelled_transaction(account: @brokerage, label: "Withdrawal", amount: 250)
      entries << create_labelled_transaction(account: @ira, label: "Contribution", amount: -300, kind: "funds_movement")
      entries << create_portfolio_trade(account: @brokerage, qty: 5, price: 10, label: "Contribution")
      entries << create_portfolio_trade(account: @brokerage, qty: -5, price: 10, label: "Withdrawal")

      internal_transfer = create_linked_transfer(family: @family, from: @brokerage, to: @ira, amount: 400, source_fee_amount: 1)
      entries << internal_transfer.outflow_transaction.entry
      entries << internal_transfer.inflow_transaction.entry
      entries << internal_transfer.fee_transactions.first.entry

      contribution = create_linked_transfer(family: @family, from: @checking, to: @brokerage, amount: 1000)
      entries << contribution.outflow_transaction.entry
      entries << contribution.inflow_transaction.entry

      entries << create_labelled_transaction(account: @brokerage, label: nil, amount: -800, kind: "funds_movement")
      entries << create_labelled_transaction(account: @ira, label: nil, amount: 200, kind: "investment_contribution")
      entries << create_labelled_transaction(account: @brokerage, label: "Transfer", amount: 60)

      entries.concat(create_security_transfer(security: security, from: @brokerage, to: @ira, qty: 10, price: 50))
      entries << create_portfolio_trade(account: @brokerage, security: create_portfolio_security, qty: 3, price: 20, label: "Transfer")
      entries << create_portfolio_trade(account: @brokerage, security: security, qty: -10, price: 50, label: "Transfer", date: 1.day.ago.to_date)

      entries << create_portfolio_trade(account: @brokerage, qty: 2, price: 10).tap { |e| e.entryable.update!(investment_activity_label: nil) }
      entries << create_portfolio_trade(account: @brokerage, qty: -2, price: 10, label: "Other")
      entries << create_labelled_transaction(account: @brokerage, label: nil, amount: -150)
      entries << create_labelled_transaction(account: @brokerage, label: "Other", amount: 75)

      entries << create_portfolio_trade(account: @brokerage, qty: 1, price: 10, excluded: true)
      entries << create_labelled_transaction(account: @brokerage, label: "Dividend", amount: -10, extra: { "plaid" => { "pending" => true } })
      # Providers write real booleans, but the flag is whatever arrived. A
      # string PostgreSQL would read as a boolean and one it cannot read at
      # all both have to classify the same way in Ruby and in SQL -- the
      # second used to abort the whole query rather than one entry.
      entries << create_labelled_transaction(account: @brokerage, label: "Dividend", amount: -11, extra: { "plaid" => { "pending" => "no" } })
      entries << create_labelled_transaction(account: @brokerage, label: "Dividend", amount: -12, extra: { "plaid" => { "pending" => "maybe" } })
      entries << create_labelled_transaction(account: @brokerage, label: "Dividend", amount: -13, extra: { "plaid" => { "pending" => "false" } })
      entries << @brokerage.entries.create!(name: "Valuation", date: Date.current, amount: 1000, currency: "USD", entryable: Valuation.new(kind: "reconciliation"))
      entries
    end
end
