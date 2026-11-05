require "test_helper"

# The rows a balance booked before it had statements hand their movements over
# to the statement rows carrying them.
class WiseItem::StatementMigrationTest < ActiveSupport::TestCase
  OWN_RECIPIENT = 70000001

  setup do
    @family = families(:empty)
    @wise_item = WiseItem.create!(family: @family, name: "Test Wise", token: "test_token", profile_id: "123", profile_type: :business)
    @eur = @wise_item.wise_accounts.create!(balance_id: "10000001", name: "Wise EUR", currency: "EUR",
                                            raw_payload: { "type" => "STANDARD", "recipient_id" => 99999001, "recipientId" => OWN_RECIPIENT })
  end

  test "a statement row takes over the transfer its reference names, and a refund credit its refund" do
    payout = transfer(101, 100, created: "2026-03-01 10:00:00", gross: "102.50 EUR")
    top_up = transfer(102, 500, created: "2026-03-02 10:00:00", target: OWN_RECIPIENT)
    refunded = transfer(103, 40, created: "2026-03-10 10:00:00", status: "funds_refunded",
                                 refund: "<positive>+ 40 EUR</positive>")
    rows = [ payout, top_up, refunded,
             statement("TRANSFER-101", "-102.50", "2026-03-01T10:05:00Z", fee: "2.50"),
             statement("TRANSFER-102", "500", "2026-03-02T10:01:00Z", type: "DEPOSIT"),
             statement("TRANSFER-103", "-40", "2026-03-10T10:01:00Z"),
             statement("TRANSFER-103", "40", "2026-03-12T09:00:00Z") ]

    result = migrate(rows)

    assert_equal "wise_statement_TRANSFER-101", row(result, 101)["wise_superseded_by"]
    assert_equal({ "main" => "wise_transfer_101", "fee" => "wise_fee_101" }, statement_row(result, "TRANSFER-101")["wise_supersedes"])
    assert_equal({ "main" => "wise_transfer_102", "fee" => "wise_fee_102" }, statement_row(result, "TRANSFER-102")["wise_supersedes"])
    debit, credit = statement_rows(result, "TRANSFER-103")
    assert_equal({ "main" => "wise_transfer_103", "fee" => "wise_fee_103" }, debit["wise_supersedes"])
    assert_equal({ "main" => "wise_refund_103" }, credit["wise_supersedes"])
    assert_equal "TRANSFER-103_CREDIT_20260312", credit["wise_statement_id"]
    assert_equal "wise_statement_TRANSFER-103", row(result, 103)["wise_superseded_by"]
    assert_equal 3, result.counts[:transfers_matched]
    assert_equal 0, result.counts[:transfers_unmatched]
  end

  # A refunded payout created before the statements' window has only its
  # refund credit inside it, and that credit, the only row with the reference,
  # took the payout over as its main row (the payout's entry became the
  # refund, its fee and refund entries went). A row takes a transfer over only
  # with the sign of the transfer's own movement. The refund credit books
  # nothing here: the transfer's row keeps booking the payout, its fee and the
  # refund. A credit for a payout that was not refunded (bounced back, say)
  # books on its own.
  test "takes a transfer over only by a row of its own sign, and lets a refunded payout from before the window keep its refund" do
    refunded = transfer(601, 100, created: "2025-12-02 10:00:00", status: "funds_refunded", gross: "102.50 EUR",
                                  refund: "<positive>+ 100 EUR</positive>")
    sent = transfer(602, 30, created: "2025-12-03 10:00:00")
    rows = [ refunded, sent,
             statement("TRANSFER-601", "100", "2025-12-17T10:00:00Z"),
             statement("TRANSFER-602", "30", "2025-12-18T10:00:00Z") ]

    result = migrate(rows)

    assert_nil row(result, 601)["wise_superseded_by"]
    assert_nil row(result, 602)["wise_superseded_by"]
    assert_equal [ "wise_refund_601", nil ], statement_row(result, "TRANSFER-601").values_at("wise_superseded_by", "wise_supersedes")
    assert_equal [ nil, nil ], statement_row(result, "TRANSFER-602").values_at("wise_superseded_by", "wise_supersedes")
    assert_equal [ 0, 0 ], result.counts.values_at(:transfers_matched, :transfers_unmatched)
  end

  # Wise documents no reference format, so a TRANSFER row of the transfer's
  # amount (a payout's gross, what a pay-in credited) within a day stands in.
  test "matches a transfer without its reference by a TRANSFER row of its amount within a day" do
    payout = transfer(201, 100, created: "2026-03-01 22:00:00", gross: "102.50 EUR")
    top_up = transfer(202, 300, created: "2026-03-03 08:00:00", target: OWN_RECIPIENT)
    rows = [ payout, top_up,
             statement("P-card", "-102.50", "2026-03-01T22:05:00Z", type: "CARD"),
             statement("P-far", "-102.50", "2026-03-04T10:00:00Z"),
             statement("P-later", "-102.50", "2026-03-02T20:00:00Z"),
             statement("P-near", "-102.50", "2026-03-02T01:00:00Z"),
             statement("P-in", "300", "2026-03-03T08:30:00Z") ]

    result = migrate(rows)

    assert_equal "wise_statement_P-near", row(result, 201)["wise_superseded_by"]
    assert_equal "wise_statement_P-in", row(result, 202)["wise_superseded_by"]
    assert_equal %w[P-card P-far P-later], result.rows.select { |r| r["wise_statement"] && r["wise_supersedes"].nil? }.map { |r| r["referenceNumber"] }
  end

  # While a booked transfer inside the statements' window has no statement
  # row, the balance keeps its transfer rows (they keep booking) and none
  # leaves, matched ones included.
  test "keeps every transfer row while one that books inside the window has no statement row" do
    rows = [ transfer(301, 10, created: "2026-03-01 10:00:00"),
             transfer(302, 20, created: "2026-04-01 10:00:00"),
             transfer(303, 30, created: "2025-12-01 10:00:00"),
             transfer(304, 40, created: "2026-04-02 10:00:00", status: "cancelled"),
             statement("TRANSFER-301", "-10", "2026-03-01T10:01:00Z") ]

    result = migrate(rows, entry_ids: ->(_ids) { [] })

    assert_equal [ 301, 302, 303, 304 ], result.rows.filter_map { |r| r["id"] }
    assert_equal [ 1, 1, 0 ], result.counts.values_at(:transfers_matched, :transfers_unmatched, :retired)
    assert_nil row(result, 302)["wise_superseded_by"]
  end

  test "retires the rows a statement row took over once the account has no entry under their ids" do
    rows = [ transfer(401, 10, created: "2026-03-01 10:00:00"), card("a", "12.50 EUR", at: "2026-03-02T10:00:00Z"),
             statement("TRANSFER-401", "-10", "2026-03-01T10:01:00Z"), statement("CARD-rid_a", "-12.50", "2026-03-02T10:00:00Z") ]
    asked = []
    fee_left = lambda do |ids|
      asked << ids.sort
      [ "wise_fee_401" ]
    end

    waiting = migrate(rows, entry_ids: fee_left)
    assert_equal [ [ "wise_activity_a", "wise_fee_401", "wise_refund_401", "wise_transfer_401" ] ], asked
    assert_equal [ 401 ], waiting.rows.filter_map { |r| r["id"] }
    assert_equal 1, waiting.counts[:retired]

    renamed = migrate(rows, entry_ids: ->(_ids) { [] })
    assert_empty renamed.rows.filter_map { |r| r["id"] }
    assert_equal [ "TRANSFER-401", "CARD-rid_a" ], renamed.rows.map { |r| r["referenceNumber"] }
    assert_equal 2, renamed.counts[:retired]

    unlinked = migrate(rows, entry_ids: nil)
    assert_equal [ 401, "a" ], unlinked.rows.filter_map { |r| r["id"] }
  end

  # Card payments booked from the activity feed before statements worked are
  # taken over by CARD-<resource id> (a refund credit sharing the reference is
  # not the payment), else by sign, amount and day. Inside the window the rest
  # is dropped, as some statement row carries it; before it, they stay.
  test "hands activities over by their reference, else by amount and day, and drops the rest of the window" do
    rows = [ card("a", "12.50 EUR", at: "2026-03-02T10:00:00Z"),
             card("b", "8 EUR", at: "2026-03-05T23:30:00Z"),
             card("c", "5 EUR", at: "2026-03-07T10:00:00Z"),
             card("d", "6 EUR", at: "2026-03-08T10:00:00Z", status: "IN_PROGRESS"),
             card("e", "7 EUR", at: "2025-11-01T10:00:00Z"),
             statement("CARD-rid_a", "12.50", "2026-03-01T10:00:00Z", type: "CARD"),
             statement("CARD-rid_a", "-12.50", "2026-03-02T10:00:00Z", type: "CARD"),
             statement("CARD-999", "-8", "2026-03-06T10:00:00Z", type: "CARD") ]

    result = migrate(rows)

    assert_equal %w[a b e], result.rows.filter_map { |r| r["id"] }
    credit, debit = statement_rows(result, "CARD-rid_a")
    assert_nil credit["wise_supersedes"]
    assert_equal({ "main" => "wise_activity_a" }, debit["wise_supersedes"])
    assert_equal "wise_statement_#{debit['wise_statement_id']}", row(result, "a")["wise_superseded_by"]
    assert_equal({ "main" => "wise_activity_b" }, statement_row(result, "CARD-999")["wise_supersedes"])
    assert_nil row(result, "e")["wise_superseded_by"]
    assert_equal [ 2, 1 ], result.counts.values_at(:activities_matched, :activities_unmatched)
  end

  # Wise's conversion rows stay (verified, they link as transfers); a
  # statement row of the same move books nothing.
  test "lets a conversion's own row book it instead of the statement row of the same move" do
    rows = [ conversion("4001", "To <strong>EUR</strong>", "117.50 EUR", "100 GBP", at: "2026-03-03T10:00:00Z"),
             conversion("6000", "To <strong>Holiday</strong>", "500 EUR", nil, at: "2026-03-04T10:00:00Z"),
             statement("BALANCE-4001", "117.50", "2026-03-03T10:00:00Z", type: "CONVERSION"),
             statement("BALANCE-4002", "50", "2026-03-03T11:00:00Z", type: "CONVERSION"),
             statement("CARD-1", "117.50", "2026-03-03T12:00:00Z", type: "CARD"),
             statement("BALANCE-6000", "-500", "2026-03-04T10:00:00Z", type: "OUTGOING_CROSS_BALANCE") ]

    result = migrate(rows)

    marks = result.rows.select { |r| r["wise_statement"] }.to_h { |r| [ r["referenceNumber"], r["wise_superseded_by"] ] }
    assert_equal({ "BALANCE-4001" => "wise_interbalance_4001_inflow", "BALANCE-4002" => nil, "CARD-1" => nil,
                   "BALANCE-6000" => "wise_interbalance_6000_outflow" }, marks)
    assert_equal 2, result.counts[:conversions_matched]
    assert_equal 2, result.rows.count { |r| r["type"] == "INTERBALANCE" }
  end

  # Wise reuses a transfer's reference on its refund: the earliest row keeps
  # it as its id.
  test "gives statement rows sharing a reference their own ids" do
    rows = [ statement("TRANSFER-555", "60", "2026-03-03T10:00:00Z"),
             statement("TRANSFER-555", "-100", "2026-03-01T10:00:00Z"),
             statement("TRANSFER-555", "40", "2026-03-03T15:00:00Z"),
             statement("CARD-1", "-5", "2026-03-03T15:00:00Z", type: "CARD") ]

    result = migrate(rows)

    assert_equal [ "TRANSFER-555_CREDIT_20260303", nil, "TRANSFER-555_CREDIT_20260303_40.0", nil ],
                 result.rows.map { |r| r["wise_statement_id"] }
  end

  test "works the marks out again from the rows, but a statement row keeps its id" do
    rows = [ transfer(501, 10, created: "2026-03-01 10:00:00").merge("wise_superseded_by" => "wise_statement_TRANSFER-501"),
             statement("CARD-1", "-5", "2026-03-03T15:00:00Z", type: "CARD")
               .merge("wise_supersedes" => { "main" => "wise_activity_x" }, "wise_statement_id" => "CARD-1_DEBIT_20260303") ]

    result = migrate(rows)

    assert result.rows.none? { |r| r.keys.intersect?(WiseItem::StatementMigration::WORKED_OUT_KEYS) }
    assert_equal "CARD-1_DEBIT_20260303", statement_row(result, "CARD-1")["wise_statement_id"]
    assert_equal 1, result.counts[:transfers_unmatched]
  end

  # The window grew back (the full history switched on), so the debit of a
  # refund booked under the plain reference turns up after it: the refund
  # keeps its id and the debit gets its own, rather than the debit taking
  # over the refund's entry.
  test "keeps a statement row's id when an earlier row with its reference turns up" do
    refund = statement("TRANSFER-9", "100", "2026-03-10T10:00:00Z")
    stored = WiseItem::StatementMigration.with_booked_ids([ refund ])
    rows = stored + [ statement("TRANSFER-9", "-100", "2026-03-01T10:00:00Z") ]

    result = migrate(rows)

    assert_equal [ "TRANSFER-9_DEBIT_20260301", "TRANSFER-9" ], statement_rows(result, "TRANSFER-9").map { |r| r["wise_statement_id"] }
  end

  # Wise refused the balance's statements after October 1: a card payment
  # after that has no statement row to hand over to, so it stays.
  test "drops no activity after the end of the statements' window" do
    card = card("after", "12 EUR", at: "2026-10-05T10:00:00Z")

    result = migrate([ card ], window: { from: Time.utc(2025, 12, 10), through: Time.utc(2026, 10, 1) })

    assert_equal [ "after" ], result.rows.map { |r| r["id"] }
    assert_equal 0, result.counts[:activities_unmatched]
  end

  # Only one stored row without an id booked under the plain reference: the
  # earliest, as Sure gave it that id.
  test "with_booked_ids gives the plain reference to the stored row that booked under it" do
    rows = [ statement("TRANSFER-7", "40", "2026-03-03T10:00:00Z"), statement("TRANSFER-7", "-100", "2026-03-01T10:00:00Z"),
             statement("TRANSFER-8", "-5", "2026-03-01T10:00:00Z").merge("wise_statement_id" => "TRANSFER-8"),
             statement("TRANSFER-8", "5", "2026-03-02T10:00:00Z") ]

    assert_equal [ nil, "TRANSFER-7", "TRANSFER-8", nil ], WiseItem::StatementMigration.with_booked_ids(rows).map { |r| r["wise_statement_id"] }
  end

  private

    # entry_ids: nil (the default) as for a balance not linked, so no row leaves.
    def migrate(rows, window: { from: Time.utc(2025, 12, 10), through: Time.utc(2026, 10, 17) }, entry_ids: nil)
      WiseItem::StatementMigration.new(@eur, rows, own_recipient_ids: @wise_item.own_recipient_ids, window: window,
                                                   entry_ids: entry_ids).call
    end

    # A same-currency transfer as /v1/transfers lists it: a payout unless it
    # targets the balance's own recipient; gross: the activity's gross debit
    # (sourceValue excludes the fee); refund: a refund credit's amount.
    def transfer(id, value, created:, target: 4242, status: "outgoing_payment_sent", gross: nil, refund: nil)
      row = { "id" => id, "targetAccount" => target, "sourceCurrency" => "EUR", "targetCurrency" => "EUR",
              "sourceValue" => value, "targetValue" => value, "status" => status, "created" => created }
      row["wise_activity"] = { "id" => "act-#{id}", "type" => "TRANSFER", "status" => "COMPLETED", "primaryAmount" => "#{value} EUR",
                               "secondaryAmount" => gross, "createdOn" => "#{created.sub(' ', 'T')}Z" } if gross
      row["wise_refund_activity"] = { "id" => "refund-#{id}", "type" => "TRANSFER", "status" => "COMPLETED", "primaryAmount" => refund } if refund
      row
    end

    def statement(reference, value, date, type: "TRANSFER", fee: nil)
      { "type" => value.to_d.negative? ? "DEBIT" : "CREDIT", "date" => date, "amount" => { "value" => value, "currency" => "EUR" },
        "totalFees" => ({ "value" => fee, "currency" => "EUR" } if fee), "details" => { "type" => type },
        "referenceNumber" => reference, "wise_statement" => true }.compact
    end

    def card(id, primary, at:, status: "COMPLETED")
      { "id" => id, "type" => "CARD_PAYMENT", "resource" => { "type" => "CARD_TRANSACTION", "id" => "rid_#{id}" },
        "title" => "<strong>Merchant</strong>", "primaryAmount" => primary, "secondaryAmount" => "", "status" => status,
        "createdOn" => at, "updatedOn" => at }
    end

    def conversion(resource_id, title, primary, secondary, at:)
      { "id" => "interbalance_#{resource_id}", "type" => "INTERBALANCE", "resource" => { "type" => "BALANCE_TRANSACTION", "id" => resource_id },
        "title" => title, "primaryAmount" => primary, "secondaryAmount" => secondary, "status" => "COMPLETED", "createdOn" => at }.compact
    end

    def row(result, id)
      result.rows.find { |r| r["id"] == id }
    end

    def statement_rows(result, reference)
      result.rows.select { |r| r["referenceNumber"] == reference }.sort_by { |r| r["date"] }
    end

    def statement_row(result, reference)
      statement_rows(result, reference).sole
    end
end
