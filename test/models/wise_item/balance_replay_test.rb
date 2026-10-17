require "test_helper"

class WiseItem::BalanceReplayTest < ActiveSupport::TestCase
  OWN_RECIPIENT = 90000001

  test "drains the merchant-currency balance and gives the rest of a split payment to the other balance" do
    conversion = conversion("conversion-1", "13 EUR", "11.31 GBP", "2026-03-01T10:00:00Z")
    payment = card("card-1", "25 EUR", "GBP, EUR", "2026-03-01T12:00:00Z")
    eur = balance("EUR", "0", [ conversion, payment ])
    gbp = balance("GBP", "28.25", [ top_up(1, "50", "GBP", "2026-03-01 09:00:00"), conversion, payment ])

    result = replay(eur, gbp)

    assert result.outcomes.all?(&:success?)
    assert_equal({ "card-1" => { "wise_split_parts" => { "GBP" => "10.44", "EUR" => "13.00" }, "wise_split_estimated" => nil } },
                 result.split_annotations)
    assert_equal({ "EUR" => Set.new, "GBP" => Set.new }, result.funding)
  end

  # Low-water rule: a part is at most the balance's lowest point until its
  # next split payment, so GBP is not left below zero after the conversion.
  test "gives each earlier split payment at most the balance's low point before the next one" do
    first = card("card-1", "20 EUR", "GBP, EUR", "2026-03-02T10:00:00Z")
    conversion = conversion("conversion-1", "94.94 EUR", "82.60 GBP", "2026-03-02T11:00:00Z")
    second = card("card-2", "10 EUR", "GBP, EUR", "2026-03-05T10:00:00Z")
    eur = balance("EUR", "0", [ first, conversion, card("card-3", "94.94 EUR", "", "2026-03-02T12:00:00Z"), second ])
    gbp = balance("GBP", "41.30", [
      top_up(1, "100", "GBP", "2026-03-01 09:00:00"), first, conversion, top_up(2, "50", "GBP", "2026-03-04 09:00:00"), second
    ])

    result = replay(eur, gbp)

    assert result.outcomes.all?(&:success?)
    assert_equal({ "GBP" => "17.40", "EUR" => "0.00" }, result.split_annotations.dig("card-1", "wise_split_parts"))
    assert_equal({ "GBP" => "8.70", "EUR" => "0.00" }, result.split_annotations.dig("card-2", "wise_split_parts"))
    # GBP paid two split payments, so its parts are estimates.
    assert_equal [ [ "GBP" ], [ "GBP" ] ], result.split_annotations.values.map { |marks| marks["wise_split_estimated"] }
  end

  # EUR reconciled, but its 13 EUR share of the payment is not written (GBP
  # did not reconcile), so what it held could hide a credit Sure misses; its
  # funding marks stay too (they used to be replaced).
  test "fails a currency whose part of a split payment is beyond the payment at the nearest rate" do
    conversion = conversion("conversion-1", "13 EUR", "11.31 GBP", "2026-03-01T10:00:00Z")
    payment = card("card-1", "25 EUR", "GBP, EUR", "2026-03-01T12:00:00Z")
    eur = balance("EUR", "0", [ conversion, payment ])
    # 30 GBP left the balance without a row, which would make GBP's part 40.44
    # for the 12 EUR the euro balance did not pay.
    gbp = balance("GBP", "28.25", [ top_up(1, "80", "GBP", "2026-03-01 09:00:00"), conversion, payment ])

    result = replay(eur, gbp)

    assert_equal({ "EUR" => nil, "GBP" => :implausible_split_part }, result.outcomes.to_h { |outcome| [ outcome.currency, outcome.reason ] })
    # EUR reconciled, but a split payment's parts are all or nothing.
    assert_empty result.split_annotations
    assert_equal :split_parts_withheld, outcome(result, "EUR").funding_withheld
    assert_empty result.funding
  end

  test "marks a payout the balance could not have paid as externally funded" do
    gbp = balance("GBP", "100", [
      top_up(1, "120", "GBP", "2025-07-29 07:26:51"),
      payout(2, "158.40", "GBP", "2025-07-30 16:09:38", target: "213 USD", gross: "160.25", updated_on: "2025-07-30T16:11:00.972Z"),
      card("card-1", "20 GBP", "", "2025-08-03T11:00:00Z")
    ])

    result = replay(gbp)

    assert result.outcomes.sole.success?
    assert_equal({ "GBP" => Set["2"] }, result.funding)
  end

  # A transfer's creation time has no fractions of a second, so the payout
  # sorts after the conversion that paid for it in the same second.
  test "puts credits before debits within the same second" do
    usd = balance("USD", "0", [
      payout(3, "100", "USD", "2026-03-01 10:00:00"),
      conversion("conversion-1", "100 USD", "80 GBP", "2026-03-01T10:00:00.700Z")
    ])

    result = replay(usd)

    assert result.outcomes.sole.success?
    assert_equal({ "USD" => Set.new }, result.funding)
  end

  # The balance could pay the payout once its activity completed, so it is
  # not externally funded; booked on its creation day it would leave the
  # balance below zero for a moment, so the currency keeps its old marks.
  test "does not call a payout externally funded when the balance could pay it once its activity completed" do
    gbp = balance("GBP", "0", [
      payout(4, "100", "GBP", "2026-03-01 10:00:00", gross: "100", updated_on: "2026-03-01T10:05:00Z"),
      top_up(5, "100", "GBP", "2026-03-01 10:01:00")
    ])

    result = replay(gbp)

    assert_equal :negative_running_balance, result.outcomes.sole.reason
    assert_empty result.funding
  end

  # A missing inflow makes a payout look unpaid, but then the replay cannot
  # end at the live amount, so nothing is marked.
  test "marks no payout when a missing inflow leaves the replay short of the live amount" do
    gbp = balance("GBP", "50", [
      top_up(1, "100", "GBP", "2026-03-01 09:00:00"),
      # A 200 GBP top-up on 2 March is missing.
      payout(6, "250", "GBP", "2026-03-03 09:00:00")
    ])

    result = replay(gbp)

    assert_equal :leftover_unexplained, result.outcomes.sole.reason
    assert_empty result.funding
  end

  test "fails a split payment the merchant-currency balance could have paid in full" do
    eur = balance("EUR", "140", [
      conversion("conversion-1", "300 EUR", "261 GBP", "2026-03-01T10:00:00Z"),
      card("card-1", "160 EUR", "GBP, EUR", "2026-03-01T12:00:00Z")
    ])

    result = replay(eur)

    assert_equal :split_payment_affordable, result.outcomes.sole.reason
    assert_empty result.split_annotations
  end

  # Wise splits a payment only when the merchant-currency balance cannot pay
  # it with its fees (up to 3 % + 2 units): holding 154 for a 150 EUR
  # withdrawal, it pays all it holds; holding 159 it could have paid it alone.
  test "drains a merchant balance holding up to the fee allowance more than the split payment" do
    atm = activity("atm-1", "CASH_WITHDRAWAL", "150 EUR", "GBP, EUR", "2026-03-04T09:00:00Z", title: "<strong>ATM</strong>")
    gbp = balance("GBP", "10", [ top_up(2, "10", "GBP", "2026-03-01 09:00:00"), atm ])

    within = replay(balance("EUR", "0", [ top_up(1, "154", "EUR", "2026-03-01 09:00:00"), atm ]), gbp)
    beyond = replay(balance("EUR", "9", [ top_up(1, "159", "EUR", "2026-03-01 09:00:00"), atm ]), gbp)

    assert within.outcomes.all?(&:success?)
    assert_equal({ "GBP" => "0.00", "EUR" => "154.00" }, within.split_annotations.dig("atm-1", "wise_split_parts"))
    assert_equal :split_payment_affordable, outcome(beyond, "EUR").reason
  end

  test "replays the rows Wise reported, not the marks an earlier replay left on them" do
    paid = payout(7, "160.25", "GBP", "2026-03-02 09:00:00").merge("wise_funding" => "external")
    split = card("card-1", "25 EUR", "GBP, EUR", "2026-03-03T09:00:00Z").merge("wise_split_parts" => { "GBP" => "9.99", "EUR" => "15.01" })
    gbp = balance("GBP", "39.75", [ top_up(1, "200", "GBP", "2026-03-01 09:00:00"), paid, split ])
    eur = balance("EUR", "0", [ top_up(2, "25", "EUR", "2026-03-01 09:00:00"), split ])

    result = replay(gbp, eur)

    assert result.outcomes.all?(&:success?)
    assert_equal Set.new, result.funding["GBP"]
    # The euro balance could pay it all; GBP lists the payment but paid nothing.
    assert_equal({ "GBP" => "0.00", "EUR" => "25.00" }, result.split_annotations.dig("card-1", "wise_split_parts"))
  end

  # Nothing bounds what CHF paid, so a debit Sure does not book could pass
  # for its part: the payment gets no parts, and both balances, whose money
  # went into it, keep their funding marks.
  test "writes no parts for a split payment one of whose parts no exchange rate bounds" do
    payment = card("card-1", "25 EUR", "CHF, EUR", "2026-03-01T12:00:00Z")
    eur = balance("EUR", "0", [ top_up(1, "11", "EUR", "2026-03-01 09:00:00"), payment ])
    chf = balance("CHF", "36", [ top_up(2, "50", "CHF", "2026-03-01 09:00:00"), payment ])

    result = replay(eur, chf)

    assert result.outcomes.all?(&:success?)
    assert_empty result.split_annotations
    assert_equal({ unbounded_part_count: 1 }, outcome(result, "CHF").notes)
    assert_equal [ :split_parts_withheld ] * 2, %w[CHF EUR].map { |currency| outcome(result, currency).funding_withheld }
    assert_empty result.funding
  end

  # The family's currency is USD, so Sure holds rates from EUR and from GBP
  # to it but none between them. 50 GBP left GBP by a debit Sure does not
  # book; without a rate that leftover would pass for GBP's part.
  test "bounds a split part with the cross rate of the rates Sure stored to a third currency" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.new(2026, 3, 1), rate: 1.08)
    ExchangeRate.create!(from_currency: "GBP", to_currency: "USD", date: Date.new(2026, 3, 2), rate: 1.26)
    payment = card("card-1", "25 EUR", "GBP, EUR", "2026-03-01T12:00:00Z")
    eur = balance("EUR", "0", [ top_up(1, "13", "EUR", "2026-03-01 09:00:00"), payment ])
    gbp = balance("GBP", "39.56", [ top_up(2, "100", "GBP", "2026-03-01 09:00:00"), payment ])

    result = WiseItem::BalanceReplay.new([ eur, gbp ], own_recipient_ids: [ OWN_RECIPIENT ]).call

    assert_equal :implausible_split_part, outcome(result, "GBP").reason
    assert_empty result.split_annotations
  end

  test "bounds a split part with a rate Sure stored when the feed has none" do
    payment = card("card-1", "25 EUR", "CHF, EUR", "2026-03-01T12:00:00Z")
    eur = balance("EUR", "0", [ top_up(1, "10", "EUR", "2026-03-01 09:00:00"), payment ])
    chf = balance("CHF", "6", [ top_up(2, "50", "CHF", "2026-03-01 09:00:00"), payment ])

    result = replay(eur, chf, stored_rate: ->(from, to, date) { BigDecimal("0.95") if [ from, to, date ] == [ "EUR", "CHF", Date.new(2026, 3, 1) ] })

    # 44 CHF for the 15 EUR the euro balance did not pay is beyond 0.95 CHF/EUR.
    assert_equal :implausible_split_part, result.outcomes.find { |outcome| outcome.currency == "CHF" }.reason
  end

  test "writes no parts for a split payment when one of its balances is not replayed" do
    eur = balance("EUR", "0", [ top_up(1, "10", "EUR", "2026-03-01 09:00:00"), card("card-1", "25 EUR", "GBP, EUR", "2026-03-01T12:00:00Z") ])

    result = replay(eur)

    assert result.outcomes.sole.success?
    assert_empty result.split_annotations
    # Nor does EUR replace its funding marks while its share is unwritten.
    assert_equal :split_parts_withheld, result.outcomes.sole.funding_withheld
    assert_empty result.funding
  end

  # A credit Sure does not book (4 GBP) makes the 93 GBP payout look unpaid;
  # with the payout taken as externally funded, the balance reconciled by
  # giving its leftover to the ATM withdrawal it shares with a euro balance
  # that is not replayed, a part never written and bounded by the whole
  # withdrawal. The balance keeps the payout booked, which its replay did not,
  # so it does not reconcile, and the payout is not marked.
  test "marks no payout when the balance's leftover went into a split part that is not written" do
    gbp = balance("GBP", "5.58", [
      top_up(1, "90", "GBP", "2026-03-01 09:00:00"),
      # missing: + 4 GBP on 2026-03-01 10:00
      payout(2, "93", "GBP", "2026-03-02 09:00:00"),
      top_up(3, "12", "GBP", "2026-03-03 09:00:00"),
      activity("atm-1", "CASH_WITHDRAWAL", "150 EUR", "GBP, EUR", "2026-03-04T09:00:00Z", title: "<strong>ATM</strong>")
    ])

    result = replay(gbp, stored_rate: ->(from, to, _date) { BigDecimal("0.87") if [ from, to ] == %w[EUR GBP] })

    assert_equal [ :funding_unconfirmed, 1 ], result.outcomes.sole.then { |outcome| [ outcome.reason, outcome.counts[:external_candidate_count] ] }
    assert_empty result.funding
    assert_empty result.split_annotations
  end

  # The same balance, but the euro balance is replayed (it paid 145 EUR of the
  # withdrawal) and no EUR/GBP rate is known. GBP reconciles only with the
  # payout taken as externally funded and a 96.42 GBP share no rate bounds, so
  # it keeps the payout's marks (none: it is booked). Written next to them,
  # that share booked the payout's 93 a second time (GBP at -87.42 for a live
  # 5.58); now GBP does not reconcile and the withdrawal keeps its parts, all
  # or nothing.
  test "writes no split part a balance worked out with a payout taken as externally funded that it keeps booked" do
    atm = activity("atm-1", "CASH_WITHDRAWAL", "150 EUR", "GBP, EUR", "2026-03-04T09:00:00Z", title: "<strong>ATM</strong>")
    eur = balance("EUR", "0", [ top_up(11, "145", "EUR", "2026-03-01 08:00:00"), atm ])
    gbp = balance("GBP", "5.58", [
      top_up(1, "90", "GBP", "2026-03-01 09:00:00"),
      # missing: + 4 GBP on 2026-03-01 10:00
      payout(2, "93", "GBP", "2026-03-02 09:00:00"),
      top_up(3, "12", "GBP", "2026-03-03 09:00:00"),
      atm
    ])

    result = replay(eur, gbp)

    assert_equal [ :funding_unconfirmed, 1 ], outcome(result, "GBP").then { |gbp_outcome| [ gbp_outcome.reason, gbp_outcome.counts[:external_candidate_count] ] }
    # The euro balance's share is unwritten too, so it keeps its marks as well.
    assert_equal [ nil, :split_parts_withheld ], outcome(result, "EUR").then { |eur_outcome| [ eur_outcome.reason, eur_outcome.funding_withheld ] }
    assert_empty result.funding
    assert_empty result.split_annotations
  end

  # The case the replay exists for: a card paid CHF's 40 CHF payout while it
  # held nothing; it then got 50 and paid 14 CHF of a 25 EUR card payment the
  # euro balance paid 11 EUR of. No EUR/CHF rate bounds the 14 CHF, so the
  # payment gets no parts and the payout keeps its marks. Unmarked, it stays
  # booked, which the replay did not do, so CHF does not reconcile (booked
  # with it, CHF came to -4 for a live 36). Marked by an earlier replay, the
  # marks fit what the replay found.
  test "a balance keeps its funding marks only when they fit the payouts its replay found externally funded" do
    payment = card("card-1", "25 EUR", "CHF, EUR", "2026-03-01T12:00:00Z")
    eur = balance("EUR", "0", [ top_up(11, "11", "EUR", "2026-03-01 09:00:00"), payment ])
    chf_rows = ->(funding) {
      [ payout(7, "40", "CHF", "2026-03-01 08:00:00").merge("wise_funding" => funding).compact,
        top_up(12, "50", "CHF", "2026-03-01 09:00:00"), payment ]
    }

    unmarked = replay(eur, balance("CHF", "36", chf_rows.call(nil)))
    marked = replay(eur, balance("CHF", "36", chf_rows.call("external")))

    assert_equal :funding_unconfirmed, outcome(unmarked, "CHF").reason
    assert_empty unmarked.funding
    assert_empty unmarked.split_annotations

    assert_equal [ nil, :split_parts_withheld ], outcome(marked, "CHF").then { |chf| [ chf.reason, chf.funding_withheld ] }
    assert_empty marked.funding
    assert_empty marked.split_annotations
  end

  # The other way round: an earlier replay marked the payout externally
  # funded, but this one finds CHF paid it, and gives its leftover (10 CHF) to
  # a split part no rate bounds. Written next to the mark CHF keeps, that part
  # would leave the payout booked nowhere.
  test "writes no split part a balance worked out with a payout it paid that its rows mark externally funded" do
    payment = card("card-1", "25 EUR", "CHF, EUR", "2026-03-01T12:00:00Z")
    eur = balance("EUR", "0", [ top_up(11, "10", "EUR", "2026-03-01 09:00:00"), payment ])
    chf = balance("CHF", "0", [
      top_up(12, "50", "CHF", "2026-03-01 08:00:00"),
      payout(7, "40", "CHF", "2026-03-01 09:00:00").merge("wise_funding" => "external"),
      payment
    ])

    result = replay(eur, chf)

    assert_equal [ :funding_unconfirmed, 0 ], outcome(result, "CHF").then { |chf_outcome| [ chf_outcome.reason, chf_outcome.counts[:external_candidate_count] ] }
    assert_empty result.funding
    assert_empty result.split_annotations
  end

  # CHF's part of a GBP card payment has no rate and was worked out with CHF's
  # payout as externally funded, so that payment keeps its parts. GBP's
  # drained part of it is then unwritten, so GBP keeps its funding marks too,
  # and its part of a euro card payment, worked out with GBP's own payout as
  # externally funded, is not written either.
  test "withholds in turn the parts of a balance whose share of a payment another balance withheld is unwritten" do
    gbp_card = card("card-gbp", "100 GBP", "CHF, GBP", "2026-03-02T12:00:00Z")
    eur_card = card("card-eur", "25 EUR", "GBP, EUR", "2026-03-04T12:00:00Z")
    chf = balance("CHF", "36", [ payout(7, "40", "CHF", "2026-03-01 08:00:00"), top_up(12, "50", "CHF", "2026-03-01 09:00:00"), gbp_card ])
    gbp = balance("GBP", "7", [
      payout(8, "30", "GBP", "2026-03-01 08:00:00"), top_up(13, "90", "GBP", "2026-03-01 09:30:00"), gbp_card,
      top_up(14, "20", "GBP", "2026-03-03 09:00:00"), eur_card
    ])
    eur = balance("EUR", "0", [ top_up(11, "10", "EUR", "2026-03-04 09:00:00"), eur_card ])

    result = replay(chf, gbp, eur, stored_rate: ->(from, to, _date) { BigDecimal("0.87") if [ from, to ] == %w[EUR GBP] })

    assert_equal({ "CHF" => [ :funding_unconfirmed, nil ], "GBP" => [ :funding_unconfirmed, nil ], "EUR" => [ nil, :split_parts_withheld ] },
                 result.outcomes.to_h { |each| [ each.currency, [ each.reason, each.funding_withheld ] ] })
    assert_empty result.funding
    assert_empty result.split_annotations
  end

  test "reads a stored exchange rate within a few days, in either direction" do
    ExchangeRate.create!(from_currency: "CHF", to_currency: "SEK", date: Date.new(2026, 3, 3), rate: 12.5)
    ExchangeRate.create!(from_currency: "CHF", to_currency: "SEK", date: Date.new(2026, 4, 6), rate: 11)

    assert_equal BigDecimal("12.5"), WiseItem::BalanceReplay.stored_rate("CHF", "SEK", Date.new(2026, 3, 1))
    assert_equal BigDecimal("0.08"), WiseItem::BalanceReplay.stored_rate("SEK", "CHF", Date.new(2026, 3, 5))
    assert_nil WiseItem::BalanceReplay.stored_rate("CHF", "SEK", Date.new(2026, 3, 20))
  end

  test "reads a cross rate through a currency Sure holds rates for with both" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.new(2026, 3, 1), rate: 1.08)
    ExchangeRate.create!(from_currency: "USD", to_currency: "GBP", date: Date.new(2026, 3, 2), rate: 0.8)

    assert_in_delta 0.864, WiseItem::BalanceReplay.stored_rate("EUR", "GBP", Date.new(2026, 3, 1)), 0.0001
    assert_in_delta 1 / 0.864, WiseItem::BalanceReplay.stored_rate("GBP", "EUR", Date.new(2026, 3, 1)), 0.0001
    assert_nil WiseItem::BalanceReplay.stored_rate("EUR", "CHF", Date.new(2026, 3, 1))
  end

  private

    def outcome(result, currency)
      result.outcomes.find { |outcome| outcome.currency == currency }
    end

    def replay(*balances, stored_rate: ->(*) { nil })
      WiseItem::BalanceReplay.new(balances, own_recipient_ids: [ OWN_RECIPIENT ], stored_rate: stored_rate).call
    end

    def balance(currency, live, rows)
      WiseItem::BalanceReplay::Balance.new(key: currency, currency: currency, live: BigDecimal(live), rows: rows)
    end

    # A transfer into the profile's own account details.
    def top_up(id, value, currency, created)
      { "id" => id, "created" => created, "status" => "outgoing_payment_sent", "targetAccount" => OWN_RECIPIENT,
        "sourceCurrency" => currency, "sourceValue" => value.to_f, "targetCurrency" => currency, "targetValue" => value.to_f }
    end

    # A transfer to someone else; with gross, the activity Wise shows for it.
    def payout(id, value, currency, created, target: "#{value} #{currency}", gross: nil, updated_on: nil)
      target_value, target_currency = target.split
      row = { "id" => id, "created" => created, "status" => "outgoing_payment_sent", "targetAccount" => 55555555,
              "sourceCurrency" => currency, "sourceValue" => value.to_f,
              "targetCurrency" => target_currency, "targetValue" => target_value.to_f }
      return row unless gross

      created_on = "#{created.sub(' ', 'T')}.500Z"
      row.merge("wise_activity" => {
        "id" => "transfer-activity-#{id}", "type" => "TRANSFER", "status" => "COMPLETED",
        "primaryAmount" => target, "secondaryAmount" => "#{gross} #{currency}",
        "createdOn" => created_on, "updatedOn" => updated_on || created_on
      })
    end

    def conversion(id, primary, secondary, created_on)
      activity(id, "INTERBALANCE", primary, secondary, created_on, title: "To <strong>#{primary.split.last}</strong>")
    end

    def card(id, primary, secondary, created_on)
      activity(id, "CARD_PAYMENT", primary, secondary, created_on, title: "<strong>Merchant</strong>")
    end

    def activity(id, type, primary, secondary, created_on, title:)
      { "id" => id, "type" => type, "resource" => { "type" => "CARD_TRANSACTION", "id" => "resource-#{id}" }, "title" => title,
        "primaryAmount" => primary, "secondaryAmount" => secondary, "status" => "COMPLETED",
        "createdOn" => created_on, "updatedOn" => created_on }
    end
end
