# frozen_string_literal: true

require "test_helper"

class RedbarkAccount::TransactionIdReissueTest < ActiveSupport::TestCase
  setup do
    @window_start = Date.new(2026, 9, 1)
  end

  test "pairs a shortened description with the row it replaced" do
    stored = [ row("A", "TRANSFER 1000000001  FROM 000-111-222333", reference: "0") ]
    fetched = [ row("B", "TRANSFER 1000000001  FROM 000-111-222", reference: "75400000000000000000001") ]

    result = detect(stored, fetched)

    assert_equal [ %w[A B] ], result.re_keys
    assert_empty result.aliases
  end

  test "pairs rows with equal real references whatever their descriptions" do
    stored = [ row("A", "CARD PURCHASE 4411", reference: "0522100624") ]
    fetched = [ row("B", "Coffee Shop Sydney", reference: "0522100624") ]

    assert_equal [ %w[A B] ], detect(stored, fetched).re_keys
  end

  test "pairs dates three days apart and no further" do
    stored = [ row("A", "TRANSFER 1000000001", date: "2026-09-10") ]

    assert_equal [ %w[A B] ], detect(stored, [ row("B", "TRANSFER 1000000001", date: "2026-09-13") ]).re_keys
    assert_empty detect(stored, [ row("B", "TRANSFER 1000000001", date: "2026-09-14") ]).re_keys
  end

  test "aliases a generated id instead of re-keying" do
    stored = [ row("A", "FALLS RESTAURANT 94.06") ]
    fetched = [ row("bank_tx_s_X", "FALLS RESTAURANT 94.06") ]

    result = detect(stored, fetched)

    assert_equal [ %w[A bank_tx_s_X] ], result.aliases
    assert_empty result.re_keys
  end

  test "leaves genuine look-alikes alone while both are still served" do
    stored = [ row("A", "FALLS RESTAURANT", reference: "476053") ]
    fetched = [ row("A", "FALLS RESTAURANT", reference: "476053"), row("C", "FALLS RESTAURANT", reference: "199002") ]

    assert_no_pairs detect(stored, fetched)
  end

  test "leaves a stored row alone while it is still served beside an identical new one" do
    stored = [ row("A", "BUS FARE 9.03") ]
    fetched = [ row("A", "BUS FARE 9.03"), row("C", "BUS FARE 9.03") ]

    assert_no_pairs detect(stored, fetched)
  end

  # A short description is a prefix of too many others: "FEE" of
  # "FEE REVERSAL", "UBER" of "UBER EATS".
  test "leaves a short description that prefixes a longer one alone" do
    assert_no_pairs detect([ row("A", "FEE") ], [ row("B", "FEE REVERSAL") ])
    assert_no_pairs detect([ row("A", "UBER EATS SYDNEY") ], [ row("B", "UBER") ])
  end

  test "pairs a prefix at the minimum length and not one character shorter" do
    shorter = "a" * RedbarkAccount::TransactionIdReissue::MIN_PREFIX_LENGTH

    assert_equal [ %w[A B] ], detect([ row("A", "#{shorter} more") ], [ row("B", shorter) ]).re_keys
    assert_no_pairs detect([ row("A", "#{shorter} more") ], [ row("B", shorter.chop) ])
  end

  test "pairs equal short descriptions" do
    assert_equal [ %w[A B] ], detect([ row("A", "FEE") ], [ row("B", "FEE") ]).re_keys
  end

  test "leaves a vanished row with no new candidate alone" do
    assert_no_pairs detect([ row("A", "TRANSFER 1") ], [ row("Z", "SOMETHING ELSE", amount: "-1.00") ])
  end

  test "leaves a vanished row with two related new rows alone" do
    stored = [ row("A", "TRANSFER 1000000001  FROM 000-111-222333") ]
    fetched = [ row("B", "TRANSFER 1000000001  FROM 000-111-222"), row("C", "TRANSFER 1000000001  FROM 000-111") ]

    assert_no_pairs detect(stored, fetched)
  end

  test "leaves twin vanished rows that match one new row alone" do
    stored = [ row("F1", "ACCOUNT FEE", reference: "9001"), row("F2", "ACCOUNT FEE", reference: "9001") ]
    fetched = [ row("G1", "ACCOUNT FEE", reference: "9001") ]

    assert_no_pairs detect(stored, fetched)
  end

  test "leaves a different amount alone" do
    assert_no_pairs detect([ row("A", "TRANSFER 1") ], [ row("B", "TRANSFER 1", amount: "-50.01") ])
  end

  test "leaves unrelated descriptions without a real reference alone" do
    assert_no_pairs detect([ row("A", "TRANSFER 1000000001") ], [ row("B", "PAYMENT RECEIVED THANK YOU") ])
  end

  test "never pairs on a shared reference across different amounts" do
    stored = [ row("A", "BVH 505.90", amount: "-505.90", reference: "0522100623") ]
    fetched = [ row("B", "BVH 486.12", amount: "-486.12", reference: "0522100623") ]

    assert_no_pairs detect(stored, fetched)
  end

  test "treats a zero reference as absent" do
    stored = [ row("A", "ACCOUNT FEE", reference: "0") ]
    fetched = [ row("B", "INTEREST CHARGED", reference: "0") ]

    assert_no_pairs detect(stored, fetched)
  end

  test "falls back to descriptions when only one row has a real reference" do
    stored = [ row("A", "TRANSFER 1000000001", reference: "0522100624") ]
    fetched = [ row("B", "PAYMENT RECEIVED", reference: "") ]

    assert_no_pairs detect(stored, fetched)
  end

  test "ignores pending rows on both sides" do
    stored = [ row("A", "TRANSFER 1", status: "pending") ]
    fetched = [ row("B", "TRANSFER 1") ]
    assert_no_pairs detect(stored, fetched)

    stored = [ row("A", "TRANSFER 1") ]
    fetched = [ row("B", "TRANSFER 1", status: "pending") ]
    assert_no_pairs detect(stored, fetched)
  end

  test "ignores stored rows dated before the fetch window" do
    stored = [ row("A", "TRANSFER 1", date: "2026-08-31") ]
    fetched = [ row("B", "TRANSFER 1", date: "2026-09-01") ]

    assert_no_pairs detect(stored, fetched)
  end

  test "does not pair a fetched id already recorded as an alias" do
    stored = [ row("A", "FALLS RESTAURANT 94.06") ]
    fetched = [ row("bank_tx_s_X", "FALLS RESTAURANT 94.06") ]

    result = RedbarkAccount::TransactionIdReissue.new(
      stored: stored, fetched: fetched, window_start: @window_start, known_alias_ids: [ "bank_tx_s_X" ]
    ).call

    assert_no_pairs result
  end

  private

    def detect(stored, fetched)
      RedbarkAccount::TransactionIdReissue.new(stored: stored, fetched: fetched, window_start: @window_start).call
    end

    def row(id, description, amount: "-50.00", date: "2026-09-10", reference: nil, status: "posted")
      { "id" => id, "status" => status, "date" => date, "amount" => amount, "description" => description, "reference" => reference }.compact
    end

    def assert_no_pairs(result)
      assert_empty result.re_keys
      assert_empty result.aliases
    end
end
