require "test_helper"

class Family::AutoTransferMatchableTest < ActiveSupport::TestCase
  include EntriesTestHelper
  include LedgerTestingHelper
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @depository = accounts(:depository)
    @credit_card = accounts(:credit_card)
    @loan = accounts(:loan)
    # A manual account with no fixture transfers to or from @depository
    @other_asset = accounts(:other_asset)
  end

  test "auto-matches transfers" do
    outflow_entry = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: @credit_card, amount: -500)

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!
    end
  end

  test "auto-matched transfers wait for confirmation before changing transaction kinds" do
    outflow_entry = create_transaction(date: Date.current, account: @depository, amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: accounts(:investment), amount: -500)

    @family.auto_match_transfers!

    transfer = Transfer.find_by!(inflow_transaction_id: inflow_entry.entryable_id)
    assert transfer.pending?
    assert_equal "standard", outflow_entry.reload.entryable.kind
    assert_equal "standard", inflow_entry.reload.entryable.kind
    assert_nil outflow_entry.entryable.category
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
        insert!({ inflow_transaction_id: rival.inflow_transaction_id, outflow_transaction_id: rival.outflow_transaction_id })
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
    # still created.
    assert Transfer.exists?(inflow_transaction_id: good_in.entryable_id, outflow_transaction_id: good_out.entryable_id)
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

  test "auto-matches multi-currency transfers between linked accounts" do
    load_exchange_prices
    link_account!(@depository)
    link_account!(@credit_card)

    create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 500)
    create_transaction(date: Date.current, account: @credit_card, amount: -700, currency: "CAD")

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!
    end

    # test match within lower bound of an explicitly widened tolerance
    create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 1000)
    create_transaction(date: Date.current, account: @credit_card, amount: -1330, currency: "CAD")

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!(exchange_rate_tolerance: 0.1)
    end

    # test match within upper bound of an explicitly widened tolerance
    create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 1500)
    create_transaction(date: Date.current, account: @credit_card, amount: -2189, currency: "CAD")

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!(exchange_rate_tolerance: 0.1)
    end

    # test no match outside of slippage tolerance, even when widened
    create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 1000)
    create_transaction(date: Date.current, account: @credit_card, amount: -1250, currency: "CAD")

    assert_difference -> { Transfer.count } => 0 do
      @family.auto_match_transfers!(exchange_rate_tolerance: 0.1)
    end
  end

  test "does not auto-match cross-currency transfers within the default tolerance when either account is manual" do
    load_exchange_prices
    # Neither @depository nor @credit_card is linked to a provider in this test,
    # so they're both "manual" -- FX-tolerance matching should not apply to them
    # even though the amounts fall within the default tolerance.
    create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 1000)
    create_transaction(date: Date.current, account: @credit_card, amount: -1400, currency: "CAD")

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end

    link_account!(@depository)

    # Still one manual leg (credit_card) -- still excluded.
    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end

    link_account!(@credit_card)

    # Both sides now linked -- the same pair matches.
    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!
    end
  end

  test "auto-matches cross-currency transfers between manual accounts with a confirmed transfer in the same direction" do
    load_family_currency_rates
    confirm_transfer!(from: @depository, to: @other_asset)

    outflow = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 400, currency: "GBP")
    inflow = create_transaction(date: Date.current, account: @other_asset, amount: -680, currency: "CAD")

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!
    end

    transfer = Transfer.find_by!(inflow_transaction_id: inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
    assert_equal "pending", transfer.status
  end

  test "a confirmed transfer in the opposite direction does not enable cross-currency auto-matching for manual accounts" do
    load_family_currency_rates
    confirm_transfer!(from: @other_asset, to: @depository)

    create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 400, currency: "GBP")
    create_transaction(date: Date.current, account: @other_asset, amount: -680, currency: "CAD")

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end
  end

  test "a pending transfer between manual accounts does not enable cross-currency auto-matching" do
    load_family_currency_rates
    confirm_transfer!(from: @depository, to: @other_asset).update!(status: "pending")

    create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 400, currency: "GBP")
    create_transaction(date: Date.current, account: @other_asset, amount: -680, currency: "CAD")

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end
  end

  test "transfer_match_candidates does not restrict cross-currency matches to linked accounts by default" do
    load_exchange_prices
    # Neither account is linked. auto_match_transfers! would exclude this pair
    # (see the test above), but a direct transfer_match_candidates call -- what
    # the manual "match as transfer" dialog uses via
    # Transaction#transfer_match_candidates -- must still surface it so a user
    # can find and confirm a real cross-currency transfer involving a manual
    # account, instead of being forced into creating a duplicate transaction.
    outflow = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 1000)
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -1400, currency: "CAD")

    assert_includes candidate_pairs, [ inflow.entryable_id, outflow.entryable_id ]
  end

  test "suggests cross-currency pairs through family currency rates when no direct rate exists" do
    load_family_currency_rates

    # 400 GBP = 500 USD ~= 694.44 CAD; the provider paid out 680 CAD (-2%)
    outflow = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 400, currency: "GBP")
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -680, currency: "CAD")

    assert_includes candidate_pairs, [ inflow.entryable_id, outflow.entryable_id ]
  end

  test "auto-matches linked cross-currency transfers through family currency rates" do
    load_family_currency_rates
    link_account!(@depository)
    link_account!(@credit_card)

    outflow = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 400, currency: "GBP")
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -680, currency: "CAD")

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!
    end

    assert Transfer.exists?(inflow_transaction_id: inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
  end

  test "derives family currency cross rates through the primary currency when the family currency is blank" do
    @family.update_column(:currency, nil)
    load_family_currency_rates

    outflow = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 400, currency: "GBP")
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -680, currency: "CAD")

    assert_includes candidate_pairs, [ inflow.entryable_id, outflow.entryable_id ]
  end

  test "does not auto-match family currency cross rates when either account is manual" do
    load_family_currency_rates

    outflow = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 400, currency: "GBP")
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -680, currency: "CAD")

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end

    link_account!(@depository)

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end

    link_account!(@credit_card)

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!
    end

    assert Transfer.exists?(inflow_transaction_id: inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
  end

  test "an exact same-currency match is not displaced by a closer cross-currency candidate" do
    load_family_currency_rates
    link_account!(@depository)
    link_account!(@credit_card)

    outflow = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 400, currency: "GBP")
    # The real counterpart arrives a day later with the exact amount...
    real_inflow = create_transaction(date: Date.current, account: @credit_card, amount: -400, currency: "GBP")
    # ...while an unrelated CAD credit on the same day falls inside the FX tolerance band.
    coincidental_inflow = create_transaction(date: 1.day.ago.to_date, account: @credit_card, amount: -680, currency: "CAD")

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!
    end

    assert Transfer.exists?(inflow_transaction_id: real_inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
    assert_not Transfer.exists?(inflow_transaction_id: coincidental_inflow.entryable_id)
  end

  test "does not auto-match a cross-currency pair whose legs have different categories" do
    load_exchange_prices
    link_account!(@depository)
    link_account!(@credit_card)

    outflow = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 500, category: categories(:food_and_drink))
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -700, currency: "CAD", category: categories(:income))

    # Otherwise eligible: the automatic path's other restrictions still offer the pair.
    eligible = @family.transfer_match_candidates(include_rejected: false, restrict_cross_currency_to_linked_accounts: true, require_common_writer: true)
    assert_includes eligible.map { |c| [ c.inflow_transaction_id, c.outflow_transaction_id ] }, [ inflow.entryable_id, outflow.entryable_id ]

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end
  end

  # A route the user confirmed is a stronger signal than the categories, which an
  # auto-categorizer can get wrong on one leg.
  test "auto-matches a cross-currency pair with different categories on a confirmed route" do
    load_family_currency_rates
    confirm_transfer!(from: @depository, to: @other_asset)

    outflow = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 400, currency: "GBP", category: categories(:food_and_drink))
    inflow = create_transaction(date: Date.current, account: @other_asset, amount: -680, currency: "CAD", category: categories(:income))

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!
    end
    assert Transfer.exists?(inflow_transaction_id: inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
  end

  # The category filter removes one row, not the inflow's slot: the greedy matcher
  # then takes the next eligible candidate, as it does after a rejected pair.
  test "a category-blocked cross-currency candidate leaves the inflow to the next eligible one" do
    load_exchange_prices
    link_account!(@depository)
    link_account!(@credit_card)

    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -700, currency: "CAD", category: categories(:income))
    blocked_outflow = create_transaction(date: Date.current, account: @depository, amount: 500, category: categories(:food_and_drink))
    next_outflow = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 505)

    # Without the category filter the blocked outflow, one day closer, ranks first.
    unfiltered = @family.transfer_match_candidates(include_rejected: false, restrict_cross_currency_to_linked_accounts: true, require_common_writer: true)
    assert_equal [ blocked_outflow.entryable_id, next_outflow.entryable_id ],
                 unfiltered.select { |c| c.inflow_transaction_id == inflow.entryable_id }.map(&:outflow_transaction_id)

    @family.auto_match_transfers!

    assert Transfer.exists?(inflow_transaction_id: inflow.entryable_id, outflow_transaction_id: next_outflow.entryable_id)
    assert_not Transfer.exists?(outflow_transaction_id: blocked_outflow.entryable_id)
  end

  test "auto-matches a cross-currency pair when either leg is uncategorized" do
    load_exchange_prices
    link_account!(@depository)
    link_account!(@credit_card)

    uncategorized_inflow_out = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 500, category: categories(:food_and_drink))
    uncategorized_inflow_in = create_transaction(date: Date.current, account: @credit_card, amount: -700, currency: "CAD")

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!
    end
    assert Transfer.exists?(inflow_transaction_id: uncategorized_inflow_in.entryable_id, outflow_transaction_id: uncategorized_inflow_out.entryable_id)

    uncategorized_outflow_out = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 1000)
    uncategorized_outflow_in = create_transaction(date: Date.current, account: @credit_card, amount: -1400, currency: "CAD", category: categories(:income))

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!
    end
    assert Transfer.exists?(inflow_transaction_id: uncategorized_outflow_in.entryable_id, outflow_transaction_id: uncategorized_outflow_out.entryable_id)
  end

  test "auto-matches a cross-currency pair whose legs share a category" do
    load_exchange_prices
    link_account!(@depository)
    link_account!(@credit_card)

    outflow = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 500, category: categories(:food_and_drink))
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -700, currency: "CAD", category: categories(:food_and_drink))

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!
    end
    assert Transfer.exists?(inflow_transaction_id: inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
  end

  test "auto-matches a same-currency exact pair whose legs have different categories" do
    outflow = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 500, category: categories(:food_and_drink))
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -500, category: categories(:income))

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!
    end
    assert Transfer.exists?(inflow_transaction_id: inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
  end

  test "a cross-currency pair with different categories can still be matched by hand" do
    load_exchange_prices
    outflow = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 500, category: categories(:food_and_drink))
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -700, currency: "CAD", category: categories(:income))

    assert_includes inflow.transaction.transfer_match_candidates.map(&:outflow_transaction_id), outflow.entryable_id

    transfer = Transfer::Matcher.new(inflow.transaction).match_with!(outflow.transaction)
    assert transfer.confirmed?
    assert_equal [ inflow.entryable_id, outflow.entryable_id ], [ transfer.inflow_transaction_id, transfer.outflow_transaction_id ]
  end

  test "a later exact same-currency match replaces a pending cross-currency guess" do
    outflow, guess = pending_cross_currency_guess

    real_inflow = create_transaction(date: Date.current, account: @credit_card, amount: -400, currency: "GBP")

    assert_no_difference -> { RejectedTransfer.count } do
      @family.auto_match_transfers!
    end

    assert_not Transfer.exists?(guess.id)
    exact = Transfer.find_by(inflow_transaction_id: real_inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
    assert exact.present?
    assert exact.pending?
  end

  test "a confirmed cross-currency transfer is never displaced by a later exact match" do
    outflow, guess = pending_cross_currency_guess
    # Confirmed with the legs still "standard", as an importer that creates a
    # confirmed Transfer without calling confirm! leaves it.
    guess.update_columns(status: "confirmed")

    real_inflow = create_transaction(date: Date.current, account: @credit_card, amount: -400, currency: "GBP")
    assert_not displacing_candidate?(real_inflow, outflow)

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end

    assert guess.reload.confirmed?
  end

  test "a pending same-currency match is not displaced by another exact match" do
    load_family_currency_rates
    link_account!(@depository)
    link_account!(@credit_card)

    outflow = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 400, currency: "GBP")
    first_inflow = create_transaction(date: 1.day.ago.to_date, account: @credit_card, amount: -400, currency: "GBP")
    @family.auto_match_transfers!
    first = Transfer.find_by!(inflow_transaction_id: first_inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)

    second_inflow = create_transaction(date: Date.current, account: @credit_card, amount: -400, currency: "GBP")
    assert_not displacing_candidate?(second_inflow, outflow)

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end

    assert Transfer.exists?(first.id)
  end

  test "a cross-currency candidate does not displace a pending cross-currency guess" do
    outflow, guess = pending_cross_currency_guess

    # Another CAD credit inside the FX band: a second guess, not an exact match.
    create_transaction(date: Date.current, account: @credit_card, amount: -680, currency: "CAD")

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end

    assert Transfer.exists?(guess.id)
    assert_equal guess.id, outflow.entryable.reload.transfer.id
  end

  test "a pending cross-currency transfer with a kind already set is not displaced" do
    outflow, guess = pending_cross_currency_guess
    # As Family::DataImporter leaves an imported pending transfer: kinds set, with a fee.
    guess.outflow_transaction.update_columns(kind: "funds_movement")
    guess.inflow_transaction.update_columns(kind: "funds_movement")
    fee = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 5, currency: "GBP")
    fee.entryable.update_columns(transfer_id: guess.id)

    real_inflow = create_transaction(date: Date.current, account: @credit_card, amount: -400, currency: "GBP")

    assert_not displacing_candidate?(real_inflow, outflow)

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end

    assert Transfer.exists?(guess.id)
    assert Transaction.exists?(fee.entryable_id)
  end

  test "a pending cross-currency guess carrying a fee is not displaced" do
    outflow, guess = pending_cross_currency_guess
    # A fee added through TransfersController#update without confirming: the
    # legs stay "standard".
    fee = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 5, currency: "GBP")
    fee.entryable.update_columns(transfer_id: guess.id)

    real_inflow = create_transaction(date: Date.current, account: @credit_card, amount: -400, currency: "GBP")
    assert_not displacing_candidate?(real_inflow, outflow)

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end

    assert guess.reload.pending?
    assert Transaction.exists?(fee.entryable_id)
  end

  test "displaced guesses are selected under a row lock" do
    outflow, guess = pending_cross_currency_guess
    real_inflow = create_transaction(date: Date.current, account: @credit_card, amount: -400, currency: "GBP")

    locking_selects = []
    callback = ->(*, payload) { locking_selects << payload[:sql] if payload[:sql].match?(/FROM "transfers".*FOR UPDATE/m) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      @family.auto_match_transfers!
    end

    assert_not Transfer.exists?(guess.id)
    assert Transfer.exists?(inflow_transaction_id: real_inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
    assert locking_selects.any?, "expected the displaced guess to be selected FOR UPDATE"
  end

  test "a later exact match replaces a pending guess holding its inflow" do
    load_family_currency_rates
    link_account!(@depository)
    link_account!(@credit_card)

    real_inflow = create_transaction(date: 1.day.ago.to_date, account: @credit_card, amount: -400, currency: "GBP")
    coincidental_outflow = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 680, currency: "CAD")
    @family.auto_match_transfers!
    guess = Transfer.find_by!(inflow_transaction_id: real_inflow.entryable_id, outflow_transaction_id: coincidental_outflow.entryable_id)
    assert guess.pending?

    outflow = create_transaction(date: Date.current, account: @depository, amount: 400, currency: "GBP")
    assert displacing_candidate?(real_inflow, outflow)

    @family.auto_match_transfers!

    assert_not Transfer.exists?(guess.id)
    assert Transfer.exists?(inflow_transaction_id: real_inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
  end

  test "a later exact match replaces pending guesses holding both its legs" do
    load_family_currency_rates
    link_account!(@depository)
    link_account!(@credit_card)

    outflow = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 400, currency: "GBP")
    real_inflow = create_transaction(date: 1.day.ago.to_date, account: @credit_card, amount: -400, currency: "GBP")
    cad_inflow = create_transaction(date: 1.day.ago.to_date, account: @credit_card, amount: -680, currency: "CAD")
    cad_outflow = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 690, currency: "CAD")
    # Each leg held by its own guess. A run would pair the exact legs first, so
    # the guesses are created directly, as an earlier run left them.
    outflow_guess = Transfer.create!(inflow_transaction: cad_inflow.entryable, outflow_transaction: outflow.entryable)
    inflow_guess = Transfer.create!(inflow_transaction: real_inflow.entryable, outflow_transaction: cad_outflow.entryable)
    assert displacing_candidate?(real_inflow, outflow)

    @family.auto_match_transfers!

    assert_not Transfer.exists?(outflow_guess.id)
    assert_not Transfer.exists?(inflow_guess.id)
    assert Transfer.exists?(inflow_transaction_id: real_inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
  end

  test "a leg held by a guess and by a confirmed transfer is not freed" do
    outflow, guess = pending_cross_currency_guess

    # The exact counterpart is already confirmed against another outflow, so
    # its leg has a blocker that is not displaceable.
    real_inflow = create_transaction(date: Date.current, account: @credit_card, amount: -400, currency: "GBP")
    other_outflow = create_transaction(date: Date.current, account: @depository, amount: 400, currency: "GBP")
    confirmed = Transfer.create!(inflow_transaction: real_inflow.entryable, outflow_transaction: other_outflow.entryable)
    confirmed.update_columns(status: "confirmed")

    assert_not displacing_candidate?(real_inflow, outflow)

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end

    assert guess.reload.pending?
    assert confirmed.reload.confirmed?
  end

  test "a failed insert of the exact pair keeps the displaced guess" do
    outflow, guess = pending_cross_currency_guess

    real_inflow = create_transaction(date: Date.current, account: @credit_card, amount: -400, currency: "GBP")
    assert displacing_candidate?(real_inflow, outflow)

    # The insert fails after the guess was destroyed in the same savepoint.
    Transfer.stubs(:find_or_create_by!).raises(ActiveRecord::RecordNotUnique)

    assert_nothing_raised { @family.auto_match_transfers! }

    assert Transfer.exists?(guess.id)
    assert_not Transfer.exists?(inflow_transaction_id: real_inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
  end

  test "a pending guess with the user's notes is not displaced" do
    outflow, guess = pending_cross_currency_guess
    # Saved from the transfer drawer without confirming: status and kinds unchanged.
    guess.update_columns(notes: "Half of the rent")

    real_inflow = create_transaction(date: Date.current, account: @credit_card, amount: -400, currency: "GBP")
    assert_not displacing_candidate?(real_inflow, outflow)

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end

    assert_equal "Half of the rent", guess.reload.notes
  end

  test "a pending guess with blank notes is still displaced" do
    outflow, guess = pending_cross_currency_guess
    guess.update_columns(notes: "  ")

    real_inflow = create_transaction(date: Date.current, account: @credit_card, amount: -400, currency: "GBP")

    @family.auto_match_transfers!

    assert_not Transfer.exists?(guess.id)
    assert Transfer.exists?(inflow_transaction_id: real_inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
  end

  # Displacement trusts an exact match more than a guess only when the exact
  # pair would itself pass the guess's category check.
  test "a later exact match in a different category does not displace a pending guess" do
    outflow, guess = pending_cross_currency_guess
    outflow.entryable.update!(category: categories(:food_and_drink))
    real_inflow = create_transaction(date: Date.current, account: @credit_card, amount: -400, currency: "GBP", category: categories(:income))

    assert_not displacing_candidate?(real_inflow, outflow)
    @family.auto_match_transfers!

    assert guess.reload.pending?
    assert_not Transfer.exists?(inflow_transaction_id: real_inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
  end

  test "a later exact match with one uncategorized leg still displaces a pending guess" do
    outflow, guess = pending_cross_currency_guess
    outflow.entryable.update!(category: categories(:food_and_drink))
    real_inflow = create_transaction(date: Date.current, account: @credit_card, amount: -400, currency: "GBP")

    @family.auto_match_transfers!

    assert_not Transfer.exists?(guess.id)
    assert Transfer.exists?(inflow_transaction_id: real_inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
  end

  test "an exact match with no guess holding its legs locks no transactions or entries" do
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -250)
    outflow = create_transaction(date: Date.current, account: @depository, amount: 250)

    locks = []
    callback = lambda do |*, payload|
      sql = payload[:sql]
      locks << sql if sql.include?("FOR UPDATE") && sql.match?(/FROM "?(transactions|entries)"?/)
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      @family.auto_match_transfers!
    end

    assert Transfer.exists?(inflow_transaction_id: inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
    assert_empty locks
  end

  test "a transfer committed for the exact pair after selection counts as the match" do
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -250)
    outflow = create_transaction(date: Date.current, account: @depository, amount: 250)
    candidate = @family.transfer_match_candidates(include_rejected: false, displace_pending_cross_currency: true).to_a
      .find { |row| row.inflow_transaction_id == inflow.entryable_id && row.outflow_transaction_id == outflow.entryable_id }
    assert candidate

    # Committed by a concurrent run between the candidate query and the insert.
    committed = Transfer.create!(inflow_transaction: inflow.entryable, outflow_transaction: outflow.entryable)

    assert_equal committed, @family.send(:find_or_create_transfer!, candidate)
  end

  test "a pair whose leg was excluded after selection does not displace the guess" do
    outflow, guess = pending_cross_currency_guess
    real_inflow = create_transaction(date: Date.current, account: @credit_card, amount: -400, currency: "GBP")
    candidates = @family.transfer_match_candidates(include_rejected: false, displace_pending_cross_currency: true).to_a
    assert candidates.any? { |row| row.inflow_transaction_id == real_inflow.entryable_id && row.outflow_transaction_id == outflow.entryable_id }

    # Excluded between the candidate query and the insert.
    real_inflow.update_columns(excluded: true)
    @family.stubs(:transfer_match_candidates).returns(candidates)

    @family.auto_match_transfers!

    assert Transfer.exists?(guess.id)
    assert_not Transfer.exists?(inflow_transaction_id: real_inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
  end

  test "auto-matching skips the run when another run holds the family's lock" do
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -250)
    outflow = create_transaction(date: Date.current, account: @depository, amount: 250)
    @family.stubs(:lock_auto_match_transfers!).returns(false)

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end
    assert_not Transfer.exists?(inflow_transaction_id: inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
  end

  test "a run skipped because the family's lock is held queues a family-wide retry" do
    family = Family.create!(name: "Retry", currency: "USD")
    family.stubs(:lock_auto_match_transfers!).returns(false)

    assert_enqueued_with(job: AutoMatchTransfersJob, args: [ family ]) do
      family.auto_match_transfers!
    end
  end

  # Fresh families, so parallel workers sharing Redis never share a key.
  test "runs skipped together queue one retry per family" do
    family = Family.create!(name: "Retry", currency: "USD")
    other_family = Family.create!(name: "Other retry", currency: "USD")
    [ family, other_family ].each do |f|
      Sidekiq.redis { |conn| conn.call("DEL", f.send(:auto_match_retry_guard_key)) }
      f.stubs(:lock_auto_match_transfers!).returns(false)
    end

    assert_enqueued_jobs 2, only: AutoMatchTransfersJob do
      3.times { family.auto_match_transfers! }
      other_family.auto_match_transfers!
    end
    assert_equal [ [ family ], [ other_family ] ],
      enqueued_jobs.select { |job| job["job_class"] == "AutoMatchTransfersJob" }.map { |job| ActiveJob::Arguments.deserialize(job["arguments"]) }
  end

  test "a pair recategorized apart after selection does not displace the guess" do
    outflow, guess = pending_cross_currency_guess
    outflow.entryable.update!(category: categories(:food_and_drink))
    real_inflow = create_transaction(date: Date.current, account: @credit_card, amount: -400, currency: "GBP")
    candidates = @family.transfer_match_candidates(include_rejected: false, displace_pending_cross_currency: true).to_a
    assert candidates.any? { |row| row.inflow_transaction_id == real_inflow.entryable_id && row.outflow_transaction_id == outflow.entryable_id }

    # Categorized as income between the candidate query and the insert.
    real_inflow.entryable.update_columns(category_id: categories(:income).id)
    @family.stubs(:transfer_match_candidates).returns(candidates)

    @family.auto_match_transfers!

    assert Transfer.exists?(guess.id)
    assert_not Transfer.exists?(inflow_transaction_id: real_inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
  end

  # A guess's own legs can be edited (a kind change) without its transfer row
  # lock, so they are locked before the guess is re-read.
  test "displacement locks the guess's legs before re-reading it" do
    _outflow, guess = pending_cross_currency_guess
    create_transaction(date: Date.current, account: @credit_card, amount: -400, currency: "GBP")

    locked_transaction_ids = []
    callback = lambda do |*, payload|
      sql = payload[:sql]
      next unless sql.include?("FOR UPDATE") && sql.match?(/FROM "?transactions"?/)

      locked_transaction_ids.concat(Array(payload[:type_casted_binds]).flatten)
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      @family.auto_match_transfers!
    end

    assert_includes locked_transaction_ids, guess.inflow_transaction_id,
      "the guess's inflow leg is locked: #{locked_transaction_ids.inspect}"
  end

  test "auto-matching takes the family's lock before it selects candidates" do
    pending_cross_currency_guess

    statements = []
    callback = ->(*, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      @family.auto_match_transfers!
    end

    lock_at = statements.index { |sql| sql.include?("pg_try_advisory_xact_lock") }
    select_at = statements.index { |sql| sql.include?("transfer_match_candidates") }
    assert lock_at, "expected a per-family advisory lock that doesn't wait"
    assert select_at, "expected the candidate query to run"
    assert_operator lock_at, :<, select_at
  end

  # Bulk confirmation locks the transfer, then saves its transactions, which
  # touch their entries. Displacement takes its locks in the same order, so
  # the two can't deadlock on one guess.
  test "displacement locks transfers before transactions before entries" do
    pending_cross_currency_guess
    create_transaction(date: Date.current, account: @credit_card, amount: -400, currency: "GBP")

    locks = []
    callback = lambda do |*, payload|
      sql = payload[:sql]
      next unless sql.include?("FOR UPDATE")

      locks << (sql[/FROM "(transfers|transactions|entries)"/, 1] || sql[/FROM (transfers|transactions|entries)\b/, 1])
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      @family.auto_match_transfers!
    end

    first_lock = locks.compact.uniq
    assert_equal %w[transfers transactions entries], first_lock, "locks taken in order: #{locks.inspect}"
  end

  # Deleting a leg locks entry, then transfer, then transaction: no order of
  # displacement's locks avoids crossing it, so displacement doesn't wait.
  test "displacement takes its row locks without waiting" do
    pending_cross_currency_guess
    create_transaction(date: Date.current, account: @credit_card, amount: -400, currency: "GBP")

    locks = {}
    callback = lambda do |*, payload|
      sql = payload[:sql]
      table = sql[/FROM "?(transfers|transactions|entries)"?/, 1]
      locks[table] ||= sql if table && sql.include?("FOR UPDATE")
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      assert_queries_match(/FOR UPDATE NOWAIT/) { @family.auto_match_transfers! }
    end

    assert_equal %w[entries transactions transfers], locks.keys.sort
    locks.each { |table, sql| assert_includes sql, "FOR UPDATE NOWAIT", "#{table} lock waits: #{sql}" }
  end

  test "a guess whose rows are locked elsewhere survives, and the run goes on" do
    outflow, guess = pending_cross_currency_guess
    real_inflow = create_transaction(date: Date.current, account: @credit_card, amount: -400, currency: "GBP")
    other_inflow = create_transaction(date: Date.current, account: @credit_card, amount: -250)
    other_outflow = create_transaction(date: Date.current, account: @depository, amount: 250)

    # A real 55P03 aborts the statement, as a NOWAIT lock held by a sync
    # deleting the leg would.
    contended_inflow_id = real_inflow.entryable_id
    original = @family.method(:exact_pair_under_lock?)
    @family.define_singleton_method(:exact_pair_under_lock?) do |match, **options|
      if match.inflow_transaction_id == contended_inflow_id
        Transfer.connection.execute("DO $$ BEGIN RAISE EXCEPTION 'row locked' USING ERRCODE = '55P03'; END $$")
      end
      original.call(match, **options)
    end

    @family.auto_match_transfers!

    assert guess.reload.pending?
    assert_not Transfer.exists?(inflow_transaction_id: real_inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
    assert Transfer.exists?(inflow_transaction_id: other_inflow.entryable_id, outflow_transaction_id: other_outflow.entryable_id)
  end

  test "a pair that stopped being exact after selection does not displace the guess" do
    outflow, guess = pending_cross_currency_guess
    real_inflow = create_transaction(date: Date.current, account: @credit_card, amount: -400, currency: "GBP")
    candidates = @family.transfer_match_candidates(include_rejected: false, displace_pending_cross_currency: true).to_a
    assert candidates.any? { |row| row.inflow_transaction_id == real_inflow.entryable_id && row.outflow_transaction_id == outflow.entryable_id }

    # Edited between the candidate query and the insert: no longer the same currency.
    real_inflow.update_columns(currency: "USD")
    @family.stubs(:transfer_match_candidates).returns(candidates)

    @family.auto_match_transfers!

    assert Transfer.exists?(guess.id)
    assert_not Transfer.exists?(inflow_transaction_id: real_inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
  end

  test "a leg held by a transfer in the other role is not paired again" do
    outflow, guess = pending_cross_currency_guess

    # X was the outflow of a confirmed transfer, then its sign was edited, so it
    # now reads as an inflow while the transfer still stores it as the outflow.
    other_inflow = create_transaction(date: Date.current, account: @depository, amount: -400, currency: "GBP")
    x = create_transaction(date: Date.current, account: @credit_card, amount: 400, currency: "GBP")
    held = Transfer.create!(inflow_transaction: other_inflow.entryable, outflow_transaction: x.entryable)
    held.update_columns(status: "confirmed")
    x.update_columns(amount: -400)

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end

    assert guess.reload.pending?
    assert_not Transfer.exists?(inflow_transaction_id: x.entryable_id)
  end

  test "displacing a pending guess keeps its legs' idempotency keys" do
    outflow, guess = pending_cross_currency_guess
    outflow.update_columns(idempotency_key: "form-retry-key")
    real_inflow = create_transaction(date: Date.current, account: @credit_card, amount: -400, currency: "GBP")

    @family.auto_match_transfers!

    assert_not Transfer.exists?(guess.id)
    assert_equal "form-retry-key", outflow.reload.idempotency_key
  end

  test "the manual match dialog still offers no exact match while a cross-currency guess holds the leg" do
    outflow, _guess = pending_cross_currency_guess
    real_inflow = create_transaction(date: Date.current, account: @credit_card, amount: -400, currency: "GBP")

    assert_not real_inflow.entryable.transfer_match_candidates.any? { |row| row.outflow_transaction_id == outflow.entryable_id }
  end

  test "does not suggest a family currency cross rate outside the exchange rate tolerance" do
    load_family_currency_rates

    outflow = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 400, currency: "GBP")
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -600, currency: "CAD")

    assert_not_includes candidate_pairs, [ inflow.entryable_id, outflow.entryable_id ]
  end

  test "the manual match dialog can still find a cross-currency counterpart on a manual account" do
    load_exchange_prices
    outflow = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 1000)
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -1400, currency: "CAD")

    # Transaction#transfer_match_candidates is what TransferMatchesController#new
    # uses to populate the "match an existing transaction" selector.
    candidates = inflow.transaction.transfer_match_candidates
    assert_includes candidates.map(&:outflow_transaction_id), outflow.entryable_id
  end

  test "the manual match dialog surfaces cross-currency matches beyond the tight automatic tolerance" do
    load_exchange_prices
    link_account!(@depository)
    link_account!(@credit_card)

    # 5% FX slippage off the cached 1.40 rate: outside an operator-tightened 3%
    # automatic tolerance, but within the 10% tolerance the manual dialog uses.
    outflow = create_transaction(date: Date.current, account: @depository, amount: 1000)
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -1470, currency: "CAD")

    with_env_overrides("TRANSFER_MATCH_EXCHANGE_RATE_TOLERANCE" => "0.03") do
      assert_no_difference -> { Transfer.count } do
        @family.auto_match_transfers!
      end

      candidates = inflow.transaction.transfer_match_candidates
      assert_includes candidates.map(&:outflow_transaction_id), outflow.entryable_id
    end
  end

  test "automatic cross-currency matching defaults to a 10% tolerance" do
    load_exchange_prices
    link_account!(@depository)
    link_account!(@credit_card)

    # 5% off the cached 1.40 rate.
    create_transaction(date: Date.current, account: @depository, amount: 1000)
    create_transaction(date: Date.current, account: @credit_card, amount: -1470, currency: "CAD")

    with_env_overrides("TRANSFER_MATCH_EXCHANGE_RATE_TOLERANCE" => nil) do
      assert_difference -> { Transfer.count } => 1 do
        @family.auto_match_transfers!
      end
    end
  end

  test "TRANSFER_MATCH_EXCHANGE_RATE_TOLERANCE sets the automatic tolerance" do
    load_exchange_prices
    link_account!(@depository)
    link_account!(@credit_card)

    # 15% off the cached 1.40 rate: outside the 10% default.
    create_transaction(date: Date.current, account: @depository, amount: 1000)
    create_transaction(date: Date.current, account: @credit_card, amount: -1610, currency: "CAD")

    with_env_overrides("TRANSFER_MATCH_EXCHANGE_RATE_TOLERANCE" => nil) do
      assert_no_difference -> { Transfer.count } do
        @family.auto_match_transfers!
      end
    end

    with_env_overrides("TRANSFER_MATCH_EXCHANGE_RATE_TOLERANCE" => "0.2") do
      assert_difference -> { Transfer.count } => 1 do
        @family.auto_match_transfers!
      end
    end
  end

  # A bad value must not fail every sync: Family::Syncer and Account::Syncer both
  # call auto_match_transfers! without a tolerance of their own.
  test "an unusable TRANSFER_MATCH_EXCHANGE_RATE_TOLERANCE falls back to the default" do
    load_exchange_prices
    link_account!(@depository)
    link_account!(@credit_card)

    [ "wide", "", "-0.1", "Infinity", "NaN" ].each do |value|
      with_env_overrides("TRANSFER_MATCH_EXCHANGE_RATE_TOLERANCE" => value) do
        assert_in_delta 0.1, Family::AutoTransferMatchable.exchange_rate_tolerance, 1e-9, "for #{value.inspect}"
      end
    end

    # 5% off the cached 1.40 rate, inside the 10% fallback.
    create_transaction(date: Date.current, account: @depository, amount: 1000)
    create_transaction(date: Date.current, account: @credit_card, amount: -1470, currency: "CAD")

    with_env_overrides("TRANSFER_MATCH_EXCHANGE_RATE_TOLERANCE" => "wide") do
      assert_difference -> { Transfer.count } => 1 do
        @family.auto_match_transfers!
      end
    end
  end

  # At 1.0 or more the lower bound reaches zero and any two cross-currency
  # amounts within the date window would match.
  test "TRANSFER_MATCH_EXCHANGE_RATE_TOLERANCE is capped at 50%" do
    load_exchange_prices
    link_account!(@depository)
    link_account!(@credit_card)

    with_env_overrides("TRANSFER_MATCH_EXCHANGE_RATE_TOLERANCE" => "5") do
      assert_in_delta 0.5, Family::AutoTransferMatchable.exchange_rate_tolerance, 1e-9
    end

    # Three times the cached 1.40 rate.
    create_transaction(date: Date.current, account: @depository, amount: 1000)
    create_transaction(date: Date.current, account: @credit_card, amount: -4200, currency: "CAD")

    with_env_overrides("TRANSFER_MATCH_EXCHANGE_RATE_TOLERANCE" => "5") do
      assert_no_difference -> { Transfer.count } do
        @family.auto_match_transfers!
      end
    end
  end

  test "the manual match dialog is never narrower than the automatic tolerance" do
    load_exchange_prices

    # 15% off the cached 1.40 rate: outside the dialog's own 10%.
    outflow = create_transaction(date: Date.current, account: @depository, amount: 1000)
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -1610, currency: "CAD")

    with_env_overrides("TRANSFER_MATCH_EXCHANGE_RATE_TOLERANCE" => "0.2") do
      candidates = inflow.transaction.transfer_match_candidates
      assert_includes candidates.map(&:outflow_transaction_id), outflow.entryable_id
    end
  end

  # linked_account_sql inlines the inverse of Account#manual?; this keeps the two
  # from drifting apart.
  test "linked_account_sql agrees with Account#manual?" do
    plain = accounts(:depository)
    via_provider = accounts(:credit_card)
    link_account!(via_provider)

    linked_ids = Account.where(id: [ plain.id, via_provider.id ])
      .where(@family.send(:linked_account_sql, "accounts"))
      .pluck(:id)

    [ plain, via_provider ].each do |account|
      assert_equal !account.reload.manual?, linked_ids.include?(account.id), account.name
    end
  end

  test "only matches inflow with correct currency when duplicate amounts exist" do
    load_exchange_prices
    link_account!(@depository)
    link_account!(@credit_card)

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

  test "does not auto-match accounts no single member can write to" do
    # family_admin owns the credit card but has no access to the loan;
    # family_member owns the loan but only has read_only on the card.
    @loan.update!(owner: users(:family_member))

    outflow = create_transaction(date: Date.current, account: @loan, amount: 500)
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -500)

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end

    # Manual matching still sees the pair; the controller scopes it per user.
    candidates = @family.transfer_match_candidates(inflow_transaction_id: inflow.entryable_id)
    assert_equal [ outflow.entryable_id ], candidates.map(&:outflow_transaction_id)
  end

  test "does not auto-match cross-currency accounts no single member can write to" do
    load_exchange_prices
    # Same ownership as above; both linked so only the writer condition blocks the match.
    @loan.update!(owner: users(:family_member))
    link_account!(@loan)
    link_account!(@credit_card)

    outflow = create_transaction(date: Date.current, account: @loan, amount: 1000)
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -1400, currency: "CAD")

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end

    assert_includes candidate_pairs, [ inflow.entryable_id, outflow.entryable_id ]
  end

  test "auto-matches across owners when a member can write to both accounts" do
    # family_member owns the loan and has full_control on the depository
    @loan.update!(owner: users(:family_member))

    create_transaction(date: Date.current, account: @depository, amount: 500)
    create_transaction(date: Date.current, account: @loan, amount: -500)

    assert_difference -> { Transfer.count }, 1 do
      @family.auto_match_transfers!
    end
  end

  test "auto-matches an owner-less account against one a member can write to" do
    # owner_id is nullified when the owner is removed; update! would reassign one
    @loan.update_column(:owner_id, nil)

    create_transaction(date: Date.current, account: @depository, amount: 500)
    create_transaction(date: Date.current, account: @loan, amount: -500)

    assert_difference -> { Transfer.count }, 1 do
      @family.auto_match_transfers!
    end
  end

  test "does not auto-match two owner-less accounts nobody can write to" do
    @loan.update_column(:owner_id, nil)
    @credit_card.update_column(:owner_id, nil)
    AccountShare.where(account: [ @loan, @credit_card ], permission: "full_control").delete_all

    create_transaction(date: Date.current, account: @credit_card, amount: 500)
    create_transaction(date: Date.current, account: @loan, amount: -500)

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
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

  test "confirmed auto-match from cash to investment assigns investment contribution category" do
    investment = accounts(:investment)
    outflow_entry = create_transaction(date: Date.current, account: @depository, amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: investment, amount: -500)

    auto_match_and_confirm_transfers!

    outflow_entry.reload

    category = @family.investment_contributions_category
    assert_equal category, outflow_entry.entryable.category
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

  test "manual transfer candidates list same-category counterparts first" do
    category = categories(:food_and_drink)
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -500, category: category)
    closer = create_transaction(date: Date.current, account: @depository, amount: 500, category: categories(:income))
    same_category = create_transaction(date: 3.days.ago.to_date, account: @other_asset, amount: 500, category: category)

    candidates = inflow.transaction.transfer_match_candidates

    assert_equal [ same_category.entryable_id, closer.entryable_id ], candidates.map(&:outflow_transaction_id)
  end

  test "single transaction transfer candidates filter optimized relation aliases" do
    outflow = create_transaction(date: Date.current, account: @depository, amount: 500)
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -500)

    outflow_candidates = outflow.transaction.transfer_match_candidates
    inflow_candidates = inflow.transaction.transfer_match_candidates

    assert_equal [ inflow.entryable_id ], outflow_candidates.map(&:inflow_transaction_id)
    assert_equal [ outflow.entryable_id ], inflow_candidates.map(&:outflow_transaction_id)
  end

  test "transaction_ids_with_transfer_candidates flags both legs of an unmatched pair" do
    outflow = create_transaction(date: 2.days.ago.to_date, account: @depository, amount: 500)
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -500)
    lone = create_transaction(date: Date.current, account: @depository, amount: 77)

    ids = @family.transaction_ids_with_transfer_candidates(
      [ outflow.transaction, inflow.transaction, lone.transaction ], user: users(:family_admin)
    )

    assert_equal Set[outflow.entryable_id, inflow.entryable_id], ids
  end

  test "transaction_ids_with_transfer_candidates only looks at the given transactions" do
    outflow = create_transaction(date: Date.current, account: @depository, amount: 500)
    create_transaction(date: Date.current, account: @credit_card, amount: -500)
    create_transaction(date: Date.current, account: @depository, amount: 600)
    create_transaction(date: Date.current, account: @credit_card, amount: -600)

    ids = @family.transaction_ids_with_transfer_candidates([ outflow.transaction ], user: users(:family_admin))

    assert_equal Set[outflow.entryable_id], ids
  end

  test "transaction_ids_with_transfer_candidates skips matched and rejected pairs" do
    outflow = create_transaction(date: Date.current, account: @depository, amount: 500)
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -500)
    RejectedTransfer.create!(inflow_transaction_id: inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)

    matched_out = create_transaction(date: Date.current, account: @depository, amount: 900)
    matched_in = create_transaction(date: Date.current, account: @credit_card, amount: -900)
    Transfer.create!(inflow_transaction: matched_in.transaction, outflow_transaction: matched_out.transaction)

    transactions = [ outflow, inflow, matched_out, matched_in ].map(&:transaction)

    assert_empty @family.transaction_ids_with_transfer_candidates(transactions, user: users(:family_admin))
  end

  test "transaction_ids_with_transfer_candidates ignores counterparts the user cannot write to" do
    @loan.update!(owner: users(:family_member))
    outflow = create_transaction(date: Date.current, account: @loan, amount: 500)
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -500)

    ids = @family.transaction_ids_with_transfer_candidates(
      [ outflow.transaction, inflow.transaction ], user: users(:family_admin)
    )

    assert_empty ids
  end

  test "transaction_ids_with_transfer_candidates finds cross-currency pairs between manual accounts" do
    ExchangeRate.create!(from_currency: "USD", to_currency: "GBP", date: Date.current, rate: 0.8)
    outflow = create_transaction(date: Date.current, account: @depository, amount: 500)
    inflow = create_transaction(date: Date.current, account: @other_asset, amount: -400, currency: "GBP")

    ids = @family.transaction_ids_with_transfer_candidates([ inflow.transaction ], user: users(:family_admin))

    assert_equal Set[inflow.entryable_id], ids
  end

  test "transaction_ids_with_transfer_candidates skips pairs whose legs carry different categories" do
    groceries = categories(:food_and_drink)
    other = categories(:income)
    purchase = create_transaction(date: Date.current, account: @depository, amount: 500, category: groceries)
    income = create_transaction(date: Date.current, account: @credit_card, amount: -500, category: other)
    half_out = create_transaction(date: Date.current, account: @depository, amount: 300, category: groceries)
    half_in = create_transaction(date: Date.current, account: @credit_card, amount: -300)

    transactions = [ purchase, income, half_out, half_in ].map(&:transaction)

    assert_empty @family.transaction_ids_with_transfer_candidates(transactions, user: users(:family_admin))
  end

  test "transaction_ids_with_transfer_candidates keeps pairs that share a category" do
    category = categories(:food_and_drink)
    outflow = create_transaction(date: Date.current, account: @depository, amount: 500, category: category)
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -500, category: category)

    ids = @family.transaction_ids_with_transfer_candidates([ outflow.transaction, inflow.transaction ], user: users(:family_admin))

    assert_equal Set[outflow.entryable_id, inflow.entryable_id], ids
  end

  test "dismiss_transfer_hint! rejects the hinted pairs of one transaction" do
    outflow = create_transaction(date: Date.current, account: @depository, amount: 500)
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -500)

    assert_difference -> { RejectedTransfer.count } => 1 do
      @family.dismiss_transfer_hint!(inflow.transaction, user: users(:family_admin))
    end

    assert_empty @family.transaction_ids_with_transfer_candidates([ outflow.transaction, inflow.transaction ], user: users(:family_admin))
    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end
    # The manual dialog still offers the pair.
    assert_equal [ outflow.entryable_id ], inflow.transaction.transfer_match_candidates.map(&:outflow_transaction_id)
  end

  test "transaction_ids_with_transfer_candidates stays narrower than the manual dialog" do
    ExchangeRate.create!(from_currency: "USD", to_currency: "GBP", date: Date.current, rate: 0.8)
    outflow = create_transaction(date: Date.current, account: @depository, amount: 500)
    # 8% off the rate: the dialog offers it, the unprompted hint does not.
    inflow = create_transaction(date: Date.current, account: @other_asset, amount: -432, currency: "GBP")
    far_outflow = create_transaction(date: 5.days.ago.to_date, account: @depository, amount: 900)
    far_inflow = create_transaction(date: Date.current, account: @credit_card, amount: -900)

    assert_equal [ outflow.entryable_id ], inflow.transaction.transfer_match_candidates.map(&:outflow_transaction_id)
    assert_empty @family.transaction_ids_with_transfer_candidates(
      [ inflow.transaction, far_outflow.transaction, far_inflow.transaction ], user: users(:family_admin)
    )
  end

  test "transfer candidate query separates exact and exchange-rate matching paths" do
    sql = @family.send(:transfer_match_candidates_sql)

    assert_includes sql, "UNION ALL"
    assert_includes sql, "inflow_candidates.excluded = FALSE"
    assert_includes sql, "outflow_candidates.excluded = FALSE"
    assert_includes sql, ":account_id IS NULL OR inflow_candidates.account_id = :account_id OR outflow_candidates.account_id = :account_id"
    assert_includes sql, "outflow_candidates.amount = -inflow_candidates.amount"
    assert_includes sql, "LEFT JOIN exchange_rates direct_rates"
    assert_includes sql, "to_currency = :family_currency"
    assert_includes sql, "EXISTS (SELECT 1 FROM account_providers WHERE account_providers.account_id = inflow_accounts.id)"
    assert_includes sql, "EXISTS (SELECT 1 FROM account_providers WHERE account_providers.account_id = outflow_accounts.id)"
    assert_includes sql, ":restrict_cross_currency_to_linked_accounts = FALSE"
    assert_equal 2, sql.scan(":require_common_writer = FALSE").size
    assert_equal 2, sql.scan(":exclude_same_connection_pairs = FALSE").size
  end

  # Moves between one Wise connection's balances are linked from Wise's own
  # activity feed (WiseItem#link_jar_transfers!); anything else the matcher
  # pairs across them is a coincidence, like a GBP top-up "matching" a USD payout.
  test "does not auto-match two balances of the same Wise connection" do
    wise_item = wise_items(:one)
    eur = link_wise_balance!(wise_item, "EUR")
    eur_jar = link_wise_balance!(wise_item, "EUR")
    gbp = link_wise_balance!(wise_item, "GBP")
    usd = link_wise_balance!(wise_item, "USD")
    ExchangeRate.create!(from_currency: "USD", to_currency: "GBP", date: Date.current, rate: 0.8156)

    # Same currency, exact amount (first UNION branch)
    jar_out = create_transaction(date: Date.current, account: eur, amount: 250.75, currency: "EUR")
    jar_in = create_transaction(date: Date.current, account: eur_jar, amount: -250.75, currency: "EUR")
    # Cross-currency inside the FX tolerance (second UNION branch)
    top_up = create_transaction(date: Date.current, account: gbp, amount: -2465, currency: "GBP")
    payout = create_transaction(date: Date.current, account: usd, amount: 3022.31, currency: "USD")

    @family.auto_match_transfers!

    assert_not Transfer.exists?(inflow_transaction_id: [ jar_in.entryable_id, top_up.entryable_id ])
    assert_not Transfer.exists?(outflow_transaction_id: [ jar_out.entryable_id, payout.entryable_id ])

    # The manual "match as transfer" dialog still offers both pairs.
    assert_includes jar_in.transaction.transfer_match_candidates.map(&:outflow_transaction_id), jar_out.entryable_id
    assert_includes top_up.transaction.transfer_match_candidates.map(&:outflow_transaction_id), payout.entryable_id
  end

  test "still auto-matches a Wise balance with a bank account or another Wise connection" do
    usd = link_wise_balance!(wise_items(:one), "USD")
    other_connection = WiseItem.create!(family: @family, name: "Personal Wise", token: "token", profile_id: "22222222",
                                        profile_type: :personal)
    other_usd = link_wise_balance!(other_connection, "USD")

    payout = create_transaction(date: Date.current, account: usd, amount: 5482.37)
    bank_credit = create_transaction(date: Date.current, account: @depository, amount: -5482.37)
    move_out = create_transaction(date: Date.current, account: usd, amount: 512.34)
    move_in = create_transaction(date: Date.current, account: other_usd, amount: -512.34)

    @family.auto_match_transfers!

    assert Transfer.exists?(inflow_transaction_id: bank_credit.entryable_id, outflow_transaction_id: payout.entryable_id)
    assert Transfer.exists?(inflow_transaction_id: move_in.entryable_id, outflow_transaction_id: move_out.entryable_id)
  end

  test "the same-connection exclusion comes from the provider adapter" do
    wise_item = wise_items(:one)
    jar_out = create_transaction(date: Date.current, account: link_wise_balance!(wise_item, "EUR"), amount: 250.75, currency: "EUR")
    jar_in = create_transaction(date: Date.current, account: link_wise_balance!(wise_item, "EUR"), amount: -250.75, currency: "EUR")
    Provider::WiseAdapter.stubs(:auto_match_exclusion_sql).returns(nil)

    @family.auto_match_transfers!

    assert Transfer.exists?(inflow_transaction_id: jar_in.entryable_id, outflow_transaction_id: jar_out.entryable_id)
  end

  test "one provider adapter's exclusion does not lift another's" do
    wise_item = wise_items(:one)
    jar_out = create_transaction(date: Date.current, account: link_wise_balance!(wise_item, "EUR"), amount: 250.75, currency: "EUR")
    jar_in = create_transaction(date: Date.current, account: link_wise_balance!(wise_item, "EUR"), amount: -250.75, currency: "EUR")
    link_account!(@depository)
    link_account!(@credit_card)
    create_transaction(date: Date.current, account: @depository, amount: 500)
    create_transaction(date: Date.current, account: @credit_card, amount: -500)
    Provider::PlaidAdapter.stubs(:auto_match_exclusion_sql).with("inflow_accounts", "outflow_accounts")
                          .returns("inflow_accounts.id = '#{@credit_card.id}'")

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end
    assert_not Transfer.exists?(inflow_transaction_id: jar_in.entryable_id, outflow_transaction_id: jar_out.entryable_id)
  end

  test "does not auto-match transfers when the family has disabled auto match" do
    @family.update!(auto_match_transfers_disabled: true)

    create_transaction(date: Date.current, account: @depository, amount: 500)
    create_transaction(date: Date.current, account: @credit_card, amount: -500)

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end
  end

  # Regression tests for loan transfer kind assignment bug
  # The kind should be determined by the DESTINATION account (inflow), not the source (outflow)
  test "loan payment (cash to loan) assigns loan_payment kind to outflow" do
    # Cash → Loan: outflow from depository, inflow to loan
    outflow_entry = create_transaction(date: Date.current, account: @depository, amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: @loan, amount: -500)

    auto_match_and_confirm_transfers!

    outflow_entry.reload
    inflow_entry.reload

    # Destination is loan account, so outflow should be loan_payment
    assert_equal "loan_payment", outflow_entry.entryable.kind
    assert_equal "funds_movement", inflow_entry.entryable.kind
  end

  test "auto-matching a principal-only loan payment re-syncs the loan" do
    @loan.loan.update_column(:principal_only_transfers, true)
    create_transaction(date: Date.current, account: @depository, amount: 500)
    create_transaction(date: Date.current, account: @loan, amount: -500)

    assert_difference -> { Sync.where(syncable: @loan).count }, 1 do
      @family.auto_match_transfers!
    end

    sync = Sync.where(syncable: @loan).order(:created_at).last
    assert_equal Date.current, sync.window_start_date
  end

  test "auto-matching a principal-only loan payment corrects the stored balance" do
    account = create_loan_account(
      initial_balance: 12_000,
      term_months: 12,
      entries: [
        { type: "opening_anchor", date: Date.new(2026, 1, 1), balance: 12_000 },
        { type: "transaction", date: Date.new(2026, 2, 1), amount: -946.19 }
      ]
    )
    enable_preview_features_for_family!(account.family)
    checking = create_checking_account(account)
    checking.entries.create!(
      name: "Payment",
      date: Date.new(2026, 2, 1),
      amount: 946.19,
      currency: checking.currency,
      entryable: Transaction.new
    )

    Balance::Materializer.new(account, strategy: :forward).materialize_balances
    assert_equal BigDecimal("11173.81"), account.balances.find_by(date: Date.new(2026, 2, 1)).balance,
                 "the unlinked replay takes the interest out of principal"

    account.loan.update_column(:principal_only_transfers, true)
    Sync.where(syncable: account).delete_all
    account.family.auto_match_transfers!

    sync = Sync.where(syncable: account).order(:created_at).last
    assert_equal Date.new(2026, 2, 1), sync.window_start_date

    Balance::Materializer.new(account, strategy: :forward, window_start_date: sync.window_start_date).materialize_balances
    assert_equal BigDecimal("11053.81"), account.balances.find_by(date: Date.new(2026, 2, 1)).balance,
                 "the follow-up sync replays the new transfer as principal only"
  end

  test "auto-matching a loan payment without the opt-in does not re-sync the loan" do
    create_transaction(date: Date.current, account: @depository, amount: 500)
    create_transaction(date: Date.current, account: @loan, amount: -500)

    assert_no_difference -> { Sync.where(syncable: @loan).count } do
      @family.auto_match_transfers!
    end
  end

  test "loan disbursement (loan to cash) assigns funds_movement kind to outflow" do
    # Loan → Cash: outflow from loan, inflow to depository
    outflow_entry = create_transaction(date: Date.current, account: @loan, amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: @depository, amount: -500)

    auto_match_and_confirm_transfers!

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

    auto_match_and_confirm_transfers!

    outflow_entry.reload
    inflow_entry.reload

    # Destination is credit card, so outflow should be cc_payment
    assert_equal "cc_payment", outflow_entry.entryable.kind
    assert_equal "funds_movement", inflow_entry.entryable.kind
  end

  private
    def auto_match_and_confirm_transfers!
      @family.auto_match_transfers!
      Transfer.pending.find_each(&:confirm!)
    end

    # Simulates a live provider connection so `Account#manual?` (and the SQL
    # query's equivalent check) treats the account as linked. `AccountProvider`
    # validates its polymorphic `provider` association is present, so this needs
    # a real (if otherwise-unused) PlaidAccount row rather than an arbitrary id.
    def link_account!(account)
      plaid_account = PlaidAccount.create!(
        plaid_item: plaid_items(:one),
        plaid_id: "acc_mock_#{SecureRandom.hex(6)}",
        name: "Linked #{account.name}",
        plaid_type: "depository",
        currency: account.currency,
        current_balance: 0
      )
      AccountProvider.create!(account: account, provider: plaid_account)
    end

    # A new account linked to a balance of the given Wise connection.
    def link_wise_balance!(wise_item, currency)
      wise_account = wise_item.wise_accounts.create!(balance_id: SecureRandom.hex(6), name: "Wise #{currency}", currency: currency)
      account = Account.create!(family: @family, owner: users(:family_admin), name: "Wise #{currency}",
                                accountable: Depository.new(subtype: "checking"), balance: 0, currency: currency)
      AccountProvider.create!(account: account, provider: wise_account)
      account
    end

    def candidate_pairs
      @family.transfer_match_candidates.map do |candidate|
        [ candidate.inflow_transaction_id, candidate.outflow_transaction_id ]
      end
    end

    def confirm_transfer!(from:, to:)
      outflow = create_transaction(date: 20.days.ago.to_date, account: from, amount: 100)
      inflow = create_transaction(date: 20.days.ago.to_date, account: to, amount: -100)
      Transfer.create!(inflow_transaction: inflow.transaction, outflow_transaction: outflow.transaction, status: "confirmed")
    end

    # A GBP outflow auto-matched (pending) to an unrelated CAD credit inside
    # the FX band, the only candidate at the time. Returns [outflow, guess].
    def pending_cross_currency_guess
      load_family_currency_rates
      link_account!(@depository)
      link_account!(@credit_card)

      outflow = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 400, currency: "GBP")
      coincidental_inflow = create_transaction(date: 1.day.ago.to_date, account: @credit_card, amount: -680, currency: "CAD")
      @family.auto_match_transfers!

      guess = Transfer.find_by!(inflow_transaction_id: coincidental_inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
      assert guess.pending?
      [ outflow, guess ]
    end

    # Whether the automatic path's candidate query offers this exact pair.
    def displacing_candidate?(inflow, outflow)
      @family.transfer_match_candidates(include_rejected: false, displace_pending_cross_currency: true).any? do |row|
        row.inflow_transaction_id == inflow.entryable_id && row.outflow_transaction_id == outflow.entryable_id
      end
    end

    # Only rates to the family currency (USD) are synced; there is no direct GBP -> CAD rate
    def load_family_currency_rates
      ExchangeRate.create!(from_currency: "GBP", to_currency: "USD", date: 1.day.ago.to_date, rate: 1.25)
      ExchangeRate.create!(from_currency: "CAD", to_currency: "USD", date: 1.day.ago.to_date, rate: 0.72)
    end

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
