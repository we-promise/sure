require "test_helper"

class Family::AutoTransferMatchableTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @depository = accounts(:depository)
    @credit_card = accounts(:credit_card)
    @loan = accounts(:loan)
  end

  test "auto-matches transfers" do
    outflow_entry = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: @credit_card, amount: -500)

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!
    end
  end

  test "concurrent unique-index race does not abort the surrounding transaction" do
    outflow_entry = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: @credit_card, amount: -500)
    inflow_id = inflow_entry.entryable_id

    # A separate matched pair whose transfer already exists, standing in for the
    # row a concurrent sync committed first. Colliding with its unique index gives
    # us a genuine failing INSERT (not a synthetic raise) -- only that aborts the
    # PostgreSQL transaction, so only that reproduces the bug.
    rival_out = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 250)
    rival_in = create_transaction(date: Date.current, account: @credit_card, amount: -250)
    rival = Transfer.create!(inflow_transaction_id: rival_in.entryable_id, outflow_transaction_id: rival_out.entryable_id)

    # A second, non-conflicting candidate: matching must CONTINUE past the skipped
    # collision and still create this transfer.
    good_out = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 700)
    good_in = create_transaction(date: Date.current, account: @credit_card, amount: -700)

    original = Transfer.method(:find_or_create_by!)
    Transfer.singleton_class.send(:define_method, :find_or_create_by!) do |attributes|
      if attributes[:inflow_transaction_id] == inflow_id
        insert!(inflow_transaction_id: rival.inflow_transaction_id, outflow_transaction_id: rival.outflow_transaction_id)
      else
        original.call(attributes)
      end
    end

    begin
      assert_nothing_raised { @family.auto_match_transfers! }
    ensure
      Transfer.singleton_class.send(:remove_method, :find_or_create_by!)
    end

    inflow_entry.reload
    outflow_entry.reload

    # The collision was with a DIFFERENT pair (the rival), so no Transfer exists for
    # THIS pair: the match is skipped, not marked. The savepoint kept the surrounding
    # transaction healthy (no abort asserted above).
    assert_nil Transfer.find_by(inflow_transaction_id: inflow_id, outflow_transaction_id: outflow_entry.entryable_id)
    refute_equal "funds_movement", inflow_entry.entryable.kind

    # ...and matching did not stop at the skip: the non-conflicting candidate was
    # still created and both its entries marked.
    good_in.reload
    good_out.reload
    assert Transfer.exists?(inflow_transaction_id: good_in.entryable_id, outflow_transaction_id: good_out.entryable_id)
    assert_equal "funds_movement", good_in.entryable.kind
    assert_equal "cc_payment", good_out.entryable.kind
  end

  test "a :taken on one column from a different pairing is skipped, not marked" do
    outflow_entry = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: @credit_card, amount: -500)

    # A concurrent sync matched this inflow to a DIFFERENT outflow, so the per-column
    # uniqueness validation raises :taken on inflow_transaction_id -- but no Transfer
    # exists for THIS (inflow, outflow) pair.
    invalid = Transfer.new(inflow_transaction_id: inflow_entry.entryable_id, outflow_transaction_id: outflow_entry.entryable_id)
    invalid.errors.add(:inflow_transaction_id, :taken)
    Transfer.stubs(:find_or_create_by!).raises(ActiveRecord::RecordInvalid.new(invalid))

    assert_nothing_raised { @family.auto_match_transfers! }

    inflow_entry.reload
    outflow_entry.reload

    # No Transfer was created for this pair, so neither transaction may be marked.
    assert_nil Transfer.find_by(inflow_transaction_id: inflow_entry.entryable_id, outflow_transaction_id: outflow_entry.entryable_id)
    refute_equal "funds_movement", inflow_entry.entryable.kind
    refute_equal "cc_payment", outflow_entry.entryable.kind
  end

  test "non-uniqueness validation failure during matching is not swallowed" do
    create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 500)
    create_transaction(date: Date.current, account: @credit_card, amount: -500)

    # A genuine (non-race) validation failure must surface, not be skipped silently.
    invalid = Transfer.new
    invalid.errors.add(:base, :different_accounts)
    Transfer.stubs(:find_or_create_by!).raises(ActiveRecord::RecordInvalid.new(invalid))

    assert_raises(ActiveRecord::RecordInvalid) { @family.auto_match_transfers! }
  end

  test "auto-matches multi-currency transfers" do
    load_exchange_prices
    create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 500)
    create_transaction(date: Date.current, account: @credit_card, amount: -700, currency: "CAD")

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!
    end

    # test match within lower 10% bound
    create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 1000)
    create_transaction(date: Date.current, account: @credit_card, amount: -1330, currency: "CAD")

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!
    end

    # test match within upper 10% bound
    create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 1500)
    create_transaction(date: Date.current, account: @credit_card, amount: -2189, currency: "CAD")

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!
    end

    # test no match outside of slippage tolerance
    create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 1000)
    create_transaction(date: Date.current, account: @credit_card, amount: -1250, currency: "CAD")

    assert_difference -> { Transfer.count } => 0 do
      @family.auto_match_transfers!
    end
  end

  test "only matches inflow with correct currency when duplicate amounts exist" do
    load_exchange_prices
    create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 500)
    create_transaction(date: Date.current, account: @credit_card, amount: -500, currency: "CAD")
    create_transaction(date: Date.current, account: @credit_card, amount: -500)

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!
    end
  end

  # In this scenario, our matching logic should find 4 potential matches.  These matches should be ranked based on
  # days apart, then de-duplicated so that we aren't auto-matching the same transaction across multiple transfers.
  test "when 2 options exist, only auto-match one at a time, ranked by days apart" do
    yesterday_outflow = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 500)
    yesterday_inflow = create_transaction(date: 1.day.ago.to_date, account: @credit_card, amount: -500)

    today_outflow = create_transaction(date: Date.current, account: @depository, amount: 500)
    today_inflow = create_transaction(date: Date.current, account: @credit_card, amount: -500)

    assert_difference -> { Transfer.count } => 2 do
      @family.auto_match_transfers!
    end
  end

  test "does not auto-match any transfers that have been rejected by user already" do
    outflow = create_transaction(date: Date.current, account: @depository, amount: 500)
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -500)

    RejectedTransfer.create!(inflow_transaction_id: inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end
  end

  test "does not consider inactive accounts when matching transfers" do
    @depository.disable!

    outflow = create_transaction(date: Date.current, account: @depository, amount: 500)
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -500)

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end

    create_transaction(date: Date.current, account: @depository, amount: 700)
    create_transaction(date: Date.current, account: @credit_card, amount: -700, excluded: true)

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end
  end

  test "does not consider excluded entries when matching transfers" do
    create_transaction(date: Date.current, account: @depository, amount: 500, excluded: true)
    create_transaction(date: Date.current, account: @credit_card, amount: -500)

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end
  end

  test "account-scoped auto-matching only considers pairs touching that account" do
    depository_outflow = create_transaction(date: Date.current, account: @depository, amount: 500)
    credit_card_inflow = create_transaction(date: Date.current, account: @credit_card, amount: -500)

    connected_outflow = create_transaction(date: Date.current, account: accounts(:connected), amount: 700)
    loan_inflow = create_transaction(date: Date.current, account: @loan, amount: -700)

    assert_difference -> { Transfer.count }, 1 do
      @family.auto_match_transfers!(account: @depository)
    end

    Transfer.find_by!(
      inflow_transaction_id: credit_card_inflow.entryable_id,
      outflow_transaction_id: depository_outflow.entryable_id
    )
    assert_nil Transfer.find_by(inflow_transaction_id: loan_inflow.entryable_id, outflow_transaction_id: connected_outflow.entryable_id)

    assert_difference -> { Transfer.count }, 1 do
      @family.auto_match_transfers!(account: accounts(:connected))
    end
  end

  test "does not match transactions outside the 4-day window" do
    create_transaction(date: 10.days.ago.to_date, account: @depository, amount: 500)
    create_transaction(date: Date.current, account: @credit_card, amount: -500)

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end
  end

  test "transfer candidate options require valid numeric input" do
    assert_raises(ArgumentError) { @family.transfer_match_candidates(date_window: "soon") }
    assert_raises(ArgumentError) { @family.transfer_match_candidates(date_window: nil) }
    assert_raises(ArgumentError) { @family.transfer_match_candidates(exchange_rate_tolerance: "wide") }
    assert_raises(ArgumentError) { @family.transfer_match_candidates(exchange_rate_tolerance: Float::INFINITY) }
    error = assert_raises(ArgumentError) { @family.transfer_match_candidates(exchange_rate_tolerance: -0.1) }
    assert_equal "exchange_rate_tolerance must be non-negative", error.message

    assert_nothing_raised do
      @family.transfer_match_candidates(date_window: "4", exchange_rate_tolerance: "0.1")
    end
  end

  test "auto-matched cash to investment assigns investment contribution category" do
    investment = accounts(:investment)
    outflow_entry = create_transaction(date: Date.current, account: @depository, amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: investment, amount: -500)

    @family.auto_match_transfers!

    outflow_entry.reload

    category = @family.investment_contributions_category
    assert_equal category, outflow_entry.entryable.category
  end

  test "auto-matched investment transfers reuse contribution category lookup" do
    investment = accounts(:investment)
    category = @family.investment_contributions_category

    create_transaction(date: Date.current, account: @depository, amount: 500)
    create_transaction(date: Date.current, account: investment, amount: -500)
    create_transaction(date: Date.current, account: @depository, amount: 700)
    create_transaction(date: Date.current, account: investment, amount: -700)

    @family.expects(:investment_contributions_category).once.returns(category)

    assert_difference -> { Transfer.count }, 2 do
      @family.auto_match_transfers!
    end
  end

  test "does not match multi-currency transfer with missing exchange rate" do
    create_transaction(date: Date.current, account: @depository, amount: 500)
    create_transaction(date: Date.current, account: @credit_card, amount: -700, currency: "GBP")

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end
  end

  test "same-currency matching ignores amount-mismatched busy-window entries" do
    noise_transaction_ids = []

    25.times do |index|
      noise_outflow = create_transaction(date: Date.current, account: @depository, amount: 13_001 + index)
      noise_inflow = create_transaction(date: Date.current, account: @credit_card, amount: -(27_001 + index))

      noise_transaction_ids << noise_outflow.entryable_id
      noise_transaction_ids << noise_inflow.entryable_id
    end

    outflow = create_transaction(date: Date.current, account: @depository, amount: 500)
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -500)

    candidate_pairs = @family.transfer_match_candidates.map do |candidate|
      [ candidate.inflow_transaction_id, candidate.outflow_transaction_id ]
    end

    assert_includes candidate_pairs, [ inflow.entryable_id, outflow.entryable_id ]

    noise_pairs = candidate_pairs.select do |inflow_transaction_id, outflow_transaction_id|
      noise_transaction_ids.include?(inflow_transaction_id) || noise_transaction_ids.include?(outflow_transaction_id)
    end

    assert_empty noise_pairs
  end

  test "single transaction transfer candidates filter optimized relation aliases" do
    outflow = create_transaction(date: Date.current, account: @depository, amount: 500)
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -500)

    outflow_candidates = outflow.transaction.transfer_match_candidates
    inflow_candidates = inflow.transaction.transfer_match_candidates

    assert_equal [ inflow.entryable_id ], outflow_candidates.map(&:inflow_transaction_id)
    assert_equal [ outflow.entryable_id ], inflow_candidates.map(&:outflow_transaction_id)
  end

  test "transfer candidate query separates exact and exchange-rate matching paths" do
    sql = @family.send(:transfer_match_candidates_sql)

    assert_includes sql, "UNION ALL"
    assert_includes sql, "inflow_candidates.excluded = FALSE"
    assert_includes sql, "outflow_candidates.excluded = FALSE"
    assert_includes sql, ":account_id IS NULL OR inflow_candidates.account_id = :account_id OR outflow_candidates.account_id = :account_id"
    assert_includes sql, "outflow_candidates.amount = -inflow_candidates.amount"
    assert_includes sql, "JOIN exchange_rates"
  end

  # Regression tests for loan transfer kind assignment bug
  # The kind should be determined by the DESTINATION account (inflow), not the source (outflow)
  test "loan payment (cash to loan) assigns loan_payment kind to outflow" do
    # Cash → Loan: outflow from depository, inflow to loan
    outflow_entry = create_transaction(date: Date.current, account: @depository, amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: @loan, amount: -500)

    @family.auto_match_transfers!

    outflow_entry.reload
    inflow_entry.reload

    # Destination is loan account, so outflow should be loan_payment
    assert_equal "loan_payment", outflow_entry.entryable.kind
    assert_equal "funds_movement", inflow_entry.entryable.kind
  end

  test "loan disbursement (loan to cash) assigns funds_movement kind to outflow" do
    # Loan → Cash: outflow from loan, inflow to depository
    outflow_entry = create_transaction(date: Date.current, account: @loan, amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: @depository, amount: -500)

    @family.auto_match_transfers!

    outflow_entry.reload
    inflow_entry.reload

    # Destination is depository (not loan), so outflow should be funds_movement
    # This ensures loan disbursements don't incorrectly appear in cashflow
    assert_equal "funds_movement", outflow_entry.entryable.kind
    assert_equal "funds_movement", inflow_entry.entryable.kind
  end

  test "credit card payment (cash to credit card) assigns cc_payment kind to outflow" do
    # Cash → Credit Card: outflow from depository, inflow to credit card
    outflow_entry = create_transaction(date: Date.current, account: @depository, amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: @credit_card, amount: -500)

    @family.auto_match_transfers!

    outflow_entry.reload
    inflow_entry.reload

    # Destination is credit card, so outflow should be cc_payment
    assert_equal "cc_payment", outflow_entry.entryable.kind
    assert_equal "funds_movement", inflow_entry.entryable.kind
  end

  private
    def load_exchange_prices
      rates = {
        4.days.ago.to_date => 1.36,
        3.days.ago.to_date => 1.37,
        2.days.ago.to_date => 1.38,
        1.day.ago.to_date  => 1.39,
        Date.current => 1.40
      }

      rates.each do |date, rate|
        # USD to CAD
        ExchangeRate.create!(
          from_currency: "USD",
          to_currency: "CAD",
          date: date,
          rate: rate
        )

        # CAD to USD (inverse)
        ExchangeRate.create!(
          from_currency: "CAD",
          to_currency: "USD",
          date: date,
          rate: (1.0 / rate).round(6)
        )
      end
    end
end
