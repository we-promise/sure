require "test_helper"

class WiseEntry::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @wise_item = WiseItem.create!(
      family: @family,
      name: "Test Wise",
      token: "test_token",
      profile_id: "123",
      profile_type: :business
    )
    @wise_account = WiseAccount.create!(
      wise_item: @wise_item,
      balance_id: "10000001",
      name: "Wise EUR",
      currency: "EUR",
      raw_payload: { "type" => "STANDARD", "recipient_id" => 99999001 }
    )
    @account = Account.create!(
      family: @family,
      name: "Wise EUR",
      accountable: Depository.new(subtype: "checking"),
      balance: 0,
      currency: "EUR"
    )
    AccountProvider.create!(account: @account, provider: @wise_account)
  end

  # Income vs expense detection

  test "imports outgoing transfer (targetAccount != recipientId) as positive expense" do
    transfer = build_transfer(id: 1001, target_account: 9999999, source_value: 500.0, target_value: 500.0)

    entry = WiseEntry::Processor.new(transfer, wise_account: @wise_account).process

    assert_equal BigDecimal("500.0"), entry.amount
    assert_equal "outgoing", entry.entryable.extra.dig("wise", "direction")
  end

  test "imports incoming transfer (targetAccount == recipientId) as negative income" do
    transfer = build_transfer(id: 1002, target_account: 99999001, source_value: 1200.0, target_value: 1200.0)

    entry = WiseEntry::Processor.new(transfer, wise_account: @wise_account).process

    assert_equal BigDecimal("-1200.0"), entry.amount
    assert_equal "incoming", entry.entryable.extra.dig("wise", "direction")
  end

  test "imports a transfer into the balance's own recipient as negative income" do
    # Top-ups and payments into a balance's account details target the balance's
    # own recipientId, not the multi-currency account's recipient_id.
    @wise_account.update!(raw_payload: { "type" => "STANDARD", "recipient_id" => 99999001, "recipientId" => 99999002 })
    transfer = build_transfer(id: 1005, target_account: 99999002, source_value: 2400.0, target_value: 2400.0)

    entry = WiseEntry::Processor.new(transfer, wise_account: @wise_account).process

    assert_equal BigDecimal("-2400.0"), entry.amount
    assert_equal "incoming", entry.entryable.extra.dig("wise", "direction")
  end

  test "books an incoming cross-currency transfer in the target currency" do
    transfer = build_transfer(id: 1003, target_account: 99999001, source_value: 100.0, target_value: 115.4,
                              source_currency: "GBP", target_currency: "EUR")

    entry = WiseEntry::Processor.new(transfer, wise_account: @wise_account).process

    assert_equal BigDecimal("-115.4"), entry.amount
    assert_equal "EUR", entry.currency
  end

  # An older build booked these pay-ins in their source currency. A
  # person's category does not make that figure theirs, so the corrected
  # one reaches the entry; an amount they changed themselves stays.
  test "corrects an entry a person categorized, but not one whose amount they changed" do
    categorized, changed = [ 1007, 1008 ].map do |id|
      @account.entries.create!(external_id: "wise_transfer_#{id}", source: "wise", amount: -100, currency: "GBP", date: Date.new(2026, 1, 15),
                               name: "Top-up", user_modified: true, entryable: Transaction.new)
    end
    changed.update!(locked_attributes: { "amount" => Time.current.iso8601 })

    [ 1007, 1008 ].each do |id|
      WiseEntry::Processor.new(build_transfer(id: id, target_account: 99999001, source_value: 100.0, target_value: 115.4,
                                              source_currency: "GBP", target_currency: "EUR"), wise_account: @wise_account).process
    end

    assert_equal [ BigDecimal("-115.4"), "EUR" ], categorized.reload.values_at(:amount, :currency)
    assert_equal [ BigDecimal("-100"), "GBP" ], changed.reload.values_at(:amount, :currency)
  end

  # Wise ends top-ups in outgoing_payment_sent like payouts, so the status
  # says nothing about direction; with no recipient known, the markup on the
  # transfer's activity decides instead.
  test "takes the direction from the activity markup when no recipient is known" do
    @wise_account.update!(raw_payload: { "type" => "STANDARD" })

    top_up = build_transfer(id: 1003, target_account: 9999, source_value: 100.0)
               .merge("wise_activity" => snapshot(primary: "<positive>+ 100 EUR</positive>"))
    entry = WiseEntry::Processor.new(top_up, wise_account: @wise_account).process
    assert_equal BigDecimal("-100.0"), entry.amount

    payout = build_transfer(id: 1004, target_account: 9999, source_value: 100.0)
               .merge("wise_activity" => snapshot(primary: "100 EUR"))
    entry = WiseEntry::Processor.new(payout, wise_account: @wise_account).process
    assert_equal BigDecimal("100.0"), entry.amount

    unenriched = build_transfer(id: 1006, target_account: 9999, source_value: 100.0)
    assert_equal BigDecimal("100.0"), WiseEntry::Processor.new(unenriched, wise_account: @wise_account).process.amount
  end

  # A top-up stays income when neither recipient id is stored.
  test "a top-up stays income without recipient ids" do
    @wise_account.update!(raw_payload: { "type" => "STANDARD" })
    top_up = build_transfer(id: 9000000104, target_account: 1_000_001, source_value: 2465.0)
               .merge("wise_activity" => snapshot(primary: "<positive>+ 2,465 EUR</positive>", title: "To EUR"))

    entry = WiseEntry::Processor.new(top_up, wise_account: @wise_account).process

    assert_equal BigDecimal("-2465"), entry.amount
  end

  # A transfer into a balance's own account details reaches that balance only,
  # the rule the importer routes by. It used to book as income on whichever
  # balance's payload held it, such as the funding side an older build stored
  # it on. A since-closed balance keeps its WiseAccount, so a top-up into it
  # stays a pay-in there and never turns into a payout when its history is
  # processed again.
  test "a transfer into a balance's own account details books on that balance only, closed balances included" do
    usd = linked_balance("USD", "10000077", raw_payload: { "type" => "STANDARD", "recipientId" => 77777001,
                                                           "closed_at" => "2026-09-01T00:00:00Z" })
    top_up = build_transfer(id: 1007, target_account: 77777001, source_value: 300.0, source_currency: "USD")
    on_eur = WiseEntry::Processor.new(top_up, wise_account: @wise_account)

    entry = WiseEntry::Processor.new(top_up, wise_account: usd).process

    assert_equal [ BigDecimal("-300.0"), "USD", "incoming" ], [ entry.amount, entry.currency, entry.entryable.extra.dig("wise", "direction") ]
    assert_equal [], on_eur.expected_external_ids
    assert_equal :skipped, on_eur.process
    assert_empty @account.entries
  end

  # An import that fails before it stores the payloads leaves them as they
  # were, and processing still books them, rows an older build put on a
  # balance included (a payout's copy on its target currency's).
  test "books nothing for a payout stored on a balance in another currency than it was paid from" do
    payout = build_transfer(id: 1009, target_account: 9999, source_currency: "GBP", target_currency: "EUR")
    processor = WiseEntry::Processor.new(payout, wise_account: @wise_account)

    assert_equal [], processor.expected_external_ids
    assert_equal :skipped, processor.process
    assert_empty @account.entries
  end

  test "own recipients come from the given list when the caller passes one" do
    transfer = build_transfer(id: 1008, target_account: 5555, source_value: 40.0)

    entry = WiseEntry::Processor.new(transfer, wise_account: @wise_account, own_recipient_ids: [ "5555" ]).process

    assert_equal BigDecimal("-40.0"), entry.amount
  end

  # Status

  test "books an outgoing transfer once Wise has funded it" do
    %w[outgoing_payment_sent processing funds_converted bounced_back waiting_recipient_input_to_proceed].each_with_index do |status, i|
      processor = WiseEntry::Processor.new(build_transfer(id: 8100 + i, target_account: 9999, status: status), wise_account: @wise_account)

      assert_equal [ "wise_transfer_#{8100 + i}" ], processor.expected_external_ids, status
      assert_kind_of Entry, processor.process, status
    end
  end

  test "skips an outgoing transfer Wise has not funded, cancelled, charged back or cannot place" do
    %w[incoming_payment_waiting incoming_payment_initiated cancelled charged_back unknown funds_credited].each_with_index do |status, i|
      processor = WiseEntry::Processor.new(build_transfer(id: 8200 + i, target_account: 9999, status: status), wise_account: @wise_account)

      assert_equal [], processor.expected_external_ids, status
      assert_equal :skipped, processor.process, status
    end
    assert_equal 0, @account.entries.where(source: "wise").count
  end

  test "books a pay-in only once Wise has sent it" do
    sent = WiseEntry::Processor.new(build_transfer(id: 8300, target_account: 99999001), wise_account: @wise_account)
    assert_equal BigDecimal("-100.0"), sent.process.amount

    %w[incoming_payment_waiting incoming_payment_initiated processing funds_converted bounced_back cancelled
       funds_refunded charged_back unknown].each_with_index do |status, i|
      processor = WiseEntry::Processor.new(build_transfer(id: 8301 + i, target_account: 99999001, status: status),
                                           wise_account: @wise_account)

      assert_equal :skipped, processor.process, status
    end
    assert_equal [ "wise_transfer_8300" ], @account.entries.where(source: "wise").pluck(:external_id)
  end

  # A cancelled payout was never funded.
  test "a cancelled transfer does not book money leaving the balance" do
    cancelled = build_transfer(id: 999001, target_account: 55555555, source_value: 158.4, target_value: 213.0,
                               source_currency: "EUR", target_currency: "USD", status: "cancelled")

    assert_equal :skipped, WiseEntry::Processor.new(cancelled, wise_account: @wise_account).process

    assert_equal 0, @account.entries.where(external_id: "wise_transfer_999001").count
  end

  test "a refunded payout books its gross debit and the refund Wise credited back" do
    refunded = build_transfer(id: 8400, target_account: 9999, source_value: 100.0, status: "funds_refunded")
                 .merge("wise_activity" => snapshot(primary: "100 EUR", secondary: "101.50 EUR"),
                        "wise_refund_activity" => snapshot(primary: "<positive>+ 99.20 EUR</positive>", id: "refund-1",
                                                           created_on: "2026-01-20T09:00:00Z"))
    processor = WiseEntry::Processor.new(refunded, wise_account: @wise_account)

    assert_equal %w[wise_transfer_8400 wise_fee_8400 wise_refund_8400], processor.expected_external_ids
    processor.process

    amounts = @account.entries.where(source: "wise").pluck(:external_id, :amount, :date).to_h { |id, amount, date| [ id, [ amount, date ] ] }
    assert_equal({ "wise_transfer_8400" => [ BigDecimal("100"), Date.new(2026, 1, 15) ],
                   "wise_fee_8400" => [ BigDecimal("1.5"), Date.new(2026, 1, 15) ],
                   "wise_refund_8400" => [ BigDecimal("-99.2"), Date.new(2026, 1, 20) ] }, amounts)
    refund_entry = @account.entries.find_by!(external_id: "wise_refund_8400")
    assert_equal I18n.t("wise_items.entries.refund_name"), refund_entry.name
    assert_equal({ "transfer_id" => 8400, "type" => "REFUND", "activity_id" => "refund-1" }, refund_entry.entryable.extra["wise"])
  end

  test "a refunded payout without a visible refund books nothing" do
    refunded = build_transfer(id: 8401, target_account: 9999, status: "funds_refunded")
                 .merge("wise_activity" => snapshot(primary: "100 EUR"))
    processor = WiseEntry::Processor.new(refunded, wise_account: @wise_account)

    assert_equal [], processor.expected_external_ids
    assert_equal :skipped, processor.process
  end

  # A refund credit Wise cancelled brought nothing back, so the refunded
  # payout books nothing (net zero), as without a refund.
  test "a refunded payout whose refund credit Wise cancelled books nothing" do
    refunded = build_transfer(id: 8404, target_account: 9999, status: "funds_refunded")
                 .merge("wise_activity" => snapshot(primary: "100 EUR", secondary: "101.20 EUR"),
                        "wise_refund_activity" => snapshot(primary: "<positive>+ 101.20 EUR</positive>", id: "refund-4", status: "CANCELLED"))
    processor = WiseEntry::Processor.new(refunded, wise_account: @wise_account)

    assert_equal [], processor.expected_external_ids
    assert_equal :skipped, processor.process
    assert_empty @account.entries
  end

  test "a refund credit on a payout Wise did not refund is not booked" do
    sent = build_transfer(id: 8402, target_account: 9999)
             .merge("wise_refund_activity" => snapshot(primary: "<positive>+ 100 EUR</positive>", id: "refund-2"))

    WiseEntry::Processor.new(sent, wise_account: @wise_account).process

    assert_equal [ "wise_transfer_8402" ], @account.entries.where(source: "wise").pluck(:external_id)
  end

  test "skips a transfer whose activity Wise cancelled" do
    transfer = build_transfer(id: 8500, target_account: 9999)
                 .merge("wise_activity" => snapshot(primary: "100 EUR", status: "CANCELLED"))

    assert_equal :skipped, WiseEntry::Processor.new(transfer, wise_account: @wise_account).process
  end

  test "skips a payout the balance replay found externally funded" do
    transfer = build_transfer(id: 8501, target_account: 9999).merge("wise_funding" => "external")
    processor = WiseEntry::Processor.new(transfer, wise_account: @wise_account)

    assert_equal [], processor.expected_external_ids
    assert_equal :skipped, processor.process
  end

  # External ID and deduplication

  test "uses stable external_id based on transfer id" do
    transfer = build_transfer(id: 2001, target_account: 9999)

    entry1 = WiseEntry::Processor.new(transfer, wise_account: @wise_account).process
    entry2 = WiseEntry::Processor.new(transfer, wise_account: @wise_account).process

    assert_equal "wise_transfer_2001", entry1.external_id
    assert_equal entry1.id, entry2.id
    assert_equal 1, @account.entries.where(source: "wise").count
  end

  # Reference as name

  test "uses details.reference as transaction name when present" do
    transfer = build_transfer(id: 3001, target_account: 9999, reference: "Invoice #42")

    entry = WiseEntry::Processor.new(transfer, wise_account: @wise_account).process

    assert_equal "Invoice #42", entry.name
  end

  test "falls back to default name when no reference" do
    transfer = build_transfer(id: 3002, target_account: 9999, reference: nil)

    entry = WiseEntry::Processor.new(transfer, wise_account: @wise_account).process

    assert_equal I18n.t("wise_items.entries.default_name"), entry.name
  end

  # Transfers used to be all named "Wise transaction".
  test "names a transfer without a reference after the counterparty in its activity" do
    payout = build_transfer(id: 3004, target_account: 9999, reference: nil)
               .merge("wise_activity" => snapshot(primary: "100 EUR", title: "Tom & Jerry"))
    referenced = build_transfer(id: 3005, target_account: 9999, reference: "Invoice #44")
                   .merge("wise_activity" => snapshot(primary: "100 EUR", title: "Tom & Jerry"))

    assert_equal "Tom & Jerry", WiseEntry::Processor.new(payout, wise_account: @wise_account).process.name
    assert_equal "Invoice #44", WiseEntry::Processor.new(referenced, wise_account: @wise_account).process.name
  end

  test "renames an existing entry when the transfer's name changes" do
    # Renaming logs a DataEnrichment under source "wise", which the enum used
    # to reject, failing the row on every later sync.
    WiseEntry::Processor.new(build_transfer(id: 3003, target_account: 9999, reference: nil),
                             wise_account: @wise_account).process

    entry = WiseEntry::Processor.new(build_transfer(id: 3003, target_account: 9999, reference: "Invoice #43"),
                                     wise_account: @wise_account).process

    assert_equal "Invoice #43", entry.reload.name
  end

  # Fee handling

  # sourceValue excludes Wise's fee (it equals targetValue on a same-currency
  # payout), so the fee now comes from the gross debit in the transfer's
  # activity; this gap is only the fallback for a transfer whose activity Sure
  # never saw.
  test "falls back to the same-currency gap between sourceValue and targetValue without an activity" do
    transfer = build_transfer(id: 4001, target_account: 9999, source_value: 100.5, target_value: 100.0)

    WiseEntry::Processor.new(transfer, wise_account: @wise_account).process

    entries = @account.entries.where(source: "wise").order(:created_at)
    assert_equal 2, entries.count

    fee_entry = entries.find { |e| e.external_id == "wise_fee_4001" }
    assert_not_nil fee_entry
    assert_equal BigDecimal("0.5"), fee_entry.amount
    assert_equal I18n.t("wise_items.entries.fee_name"), fee_entry.name
  end

  test "does not create fee entry when sourceValue equals targetValue" do
    transfer = build_transfer(id: 4002, target_account: 9999, source_value: 200.0, target_value: 200.0)

    WiseEntry::Processor.new(transfer, wise_account: @wise_account).process

    assert_equal 1, @account.entries.where(source: "wise").count
  end

  # With its activity a cross-currency payout does get a fee (see below);
  # without it there is nothing in the source currency to compare.
  test "does not guess a cross-currency fee without an activity" do
    transfer = build_transfer(id: 4003, target_account: 9999, source_value: 100.0, target_value: 90.0,
                               source_currency: "EUR", target_currency: "GBP")

    WiseEntry::Processor.new(transfer, wise_account: @wise_account).process

    assert_equal 1, @account.entries.where(source: "wise").count
  end

  # A payout that debited 5,492.01 USD for a 5,482.37 sourceValue.
  test "a same-currency payout lowers the balance by what Wise debited, fee included" do
    transfer = build_transfer(id: 9000000103, target_account: 55555555, source_value: 5482.37)
                 .merge("wise_activity" => snapshot(primary: "5,482.37 EUR", secondary: "5,492.01 EUR"))

    WiseEntry::Processor.new(transfer, wise_account: @wise_account).process

    amounts = @account.entries.where(source: "wise").pluck(:external_id, :amount).to_h
    assert_equal({ "wise_transfer_9000000103" => BigDecimal("5482.37"), "wise_fee_9000000103" => BigDecimal("9.64") }, amounts)
  end

  test "takes a cross-currency payout's fee from the gross debit in its source currency" do
    # A payout of 158.40 GBP converted to 213.00 USD, 160.25 GBP debited.
    gbp = linked_balance("GBP", "10000003")
    transfer = build_transfer(id: 9000000102, target_account: 55555555, source_value: 158.4, target_value: 213.0,
                              source_currency: "GBP", target_currency: "USD", rate: 1.3874)
                 .merge("wise_activity" => snapshot(primary: "213 USD", secondary: "160.25 GBP"))
    processor = WiseEntry::Processor.new(transfer, wise_account: gbp)

    assert_equal %w[wise_transfer_9000000102 wise_fee_9000000102], processor.expected_external_ids
    entry = processor.process

    assert_equal BigDecimal("158.40"), entry.amount
    assert_equal BigDecimal("1.85"), gbp.current_account.entries.find_by!(external_id: "wise_fee_9000000102").amount
    assert_equal BigDecimal("1.85"), entry.entryable.extra.dig("wise", "fee").to_d
    assert_equal "act-1", entry.entryable.extra.dig("wise", "activity_id")
  end

  test "books no fee when the activity shows no more than sourceValue" do
    transfer = build_transfer(id: 4005, target_account: 9999, source_value: 100.5, target_value: 100.0)
                 .merge("wise_activity" => snapshot(primary: "100.50 EUR", secondary: "100.504 EUR"))

    WiseEntry::Processor.new(transfer, wise_account: @wise_account).process

    assert_equal [ "wise_transfer_4005" ], @account.entries.where(source: "wise").pluck(:external_id)
  end

  test "never books a fee on a pay-in" do
    transfer = build_transfer(id: 4006, target_account: 99999001, source_value: 100.5, target_value: 100.0)
                 .merge("wise_activity" => snapshot(primary: "<positive>+ 100 EUR</positive>", secondary: "101.20 EUR"))
    processor = WiseEntry::Processor.new(transfer, wise_account: @wise_account)

    assert_equal [ "wise_transfer_4006" ], processor.expected_external_ids
    processor.process

    assert_equal({ "wise_transfer_4006" => BigDecimal("-100") }, @account.entries.where(source: "wise").pluck(:external_id, :amount).to_h)
  end

  test "re-importing a transfer drops wise metadata Wise no longer reports" do
    WiseEntry::Processor.new(build_transfer(id: 4004, target_account: 9999, source_value: 100.5, target_value: 100.0),
                             wise_account: @wise_account).process

    entry = WiseEntry::Processor.new(build_transfer(id: 4004, target_account: 9999, source_value: 100.0, target_value: 100.0),
                                     wise_account: @wise_account).process

    assert_nil entry.entryable.reload.extra.dig("wise", "fee")
  end

  # A fee's and a refund's wise namespace is replaced on every import too, so
  # a key Sure no longer writes there goes.
  test "re-importing a refunded payout drops wise metadata its fee and refund no longer carry" do
    refunded = build_transfer(id: 8403, target_account: 9999, status: "funds_refunded")
                 .merge("wise_activity" => snapshot(primary: "100 EUR", secondary: "101.50 EUR"),
                        "wise_refund_activity" => snapshot(primary: "<positive>+ 99.20 EUR</positive>", id: "refund-3"))
    WiseEntry::Processor.new(refunded, wise_account: @wise_account).process
    fee, refund = %w[wise_fee_8403 wise_refund_8403].map { |id| @account.entries.find_by!(external_id: id).entryable }
    fee.update_column(:extra, fee.extra.deep_merge("wise" => { "status" => "outgoing_payment_sent" }))

    WiseEntry::Processor.new(refunded.merge("wise_refund_activity" => refunded["wise_refund_activity"].except("id")),
                             wise_account: @wise_account).process

    assert_equal({ "transfer_id" => 8403, "type" => "FEE" }, fee.reload.extra["wise"])
    assert_equal({ "transfer_id" => 8403, "type" => "REFUND" }, refund.reload.extra["wise"])
  end

  # Dates

  test "reads created as UTC whatever the server time zone" do
    @family.update!(timezone: "Europe/Dublin")
    transfer = build_transfer(id: 7001, target_account: 9999).merge("created" => "2026-06-30 23:30:00")

    entry = with_server_time_zone("Europe/Dublin") do
      WiseEntry::Processor.new(transfer, wise_account: @wise_account).process
    end

    # Wise sends created in UTC without a zone designator: 23:30 UTC is 00:30
    # on 1 July in Dublin (IST).
    assert_equal Date.new(2026, 7, 1), entry.date
  end

  test "created_at is the UTC instant of created" do
    with_server_time_zone("Asia/Tokyo") do
      assert_equal Time.utc(2026, 6, 30, 23, 30), WiseEntry::Processor.created_at({ "created" => "2026-06-30 23:30:00" })
    end
    assert_nil WiseEntry::Processor.created_at({ "created" => nil })
  end

  # Exchange rate for balance conversion

  test "stores the Wise exchange rate for cross-currency transfers" do
    # Paid from the balance's currency.
    transfer = build_transfer(id: 6001, target_account: 9999, source_value: 1828.25,
                              target_value: 1372.47, source_currency: "EUR",
                              target_currency: "USD", rate: 0.7507)

    entry = WiseEntry::Processor.new(transfer, wise_account: @wise_account).process

    assert_equal BigDecimal("0.7507"), entry.entryable.extra.dig("exchange_rate").to_d
    assert_equal BigDecimal("0.7507"), entry.entryable.extra.dig("wise", "rate").to_d
  end

  test "omits exchange_rate when Wise does not report a rate" do
    transfer = build_transfer(id: 6002, target_account: 9999)
    transfer["rate"] = nil

    entry = WiseEntry::Processor.new(transfer, wise_account: @wise_account).process

    assert_nil entry.entryable.extra.dig("exchange_rate")
  end

  # Skips without linked account

  test "returns skipped when no account linked" do
    unlinked_account = WiseAccount.create!(
      wise_item: @wise_item,
      balance_id: "10000099",
      name: "Unlinked",
      currency: "GBP"
    )

    result = WiseEntry::Processor.new(build_transfer(id: 5001, target_account: 9999),
                                       wise_account: unlinked_account).process

    assert_equal :skipped, result
  end

  # Extra metadata

  test "stores wise metadata in entry extra" do
    transfer = build_transfer(id: 6001, target_account: 9999, source_value: 50.0, reference: "test ref")

    entry = WiseEntry::Processor.new(transfer, wise_account: @wise_account).process

    extra = entry.entryable.extra
    assert_equal 6001, extra.dig("wise", "transfer_id")
    assert_equal "outgoing_payment_sent", extra.dig("wise", "status")
    assert_equal "EUR", extra.dig("wise", "source_currency")
    assert_equal "test ref", extra.dig("wise", "reference")
  end

  private

    def linked_balance(currency, balance_id, raw_payload: { "type" => "STANDARD" })
      wise_account = WiseAccount.create!(wise_item: @wise_item, balance_id: balance_id, name: "Wise #{currency}",
                                         currency: currency, raw_payload: raw_payload)
      account = Account.create!(family: @family, name: "Wise #{currency}", accountable: Depository.new(subtype: "checking"),
                                balance: 0, currency: currency)
      AccountProvider.create!(account: account, provider: wise_account)
      wise_account
    end

    # Time.parse reads a zone-less string in the process time zone (ENV["TZ"]).
    def with_server_time_zone(zone)
      previous = ENV["TZ"]
      ENV["TZ"] = zone
      yield
    ensure
      ENV["TZ"] = previous
    end

    # The transfer's activity as the importer attaches it ("wise_activity"):
    # Wise's amount strings with their markup and a plain-text title.
    def snapshot(primary:, secondary: nil, status: "COMPLETED", title: "Recipient", id: "act-1",
                 created_on: "2026-01-15T10:00:01Z")
      { "id" => id, "type" => "TRANSFER", "status" => status, "primaryAmount" => primary, "secondaryAmount" => secondary,
        "title" => title, "description" => "Sent", "createdOn" => created_on, "updatedOn" => created_on }.compact
    end

    def build_transfer(id:, target_account:, source_value: 100.0, target_value: nil,
                        source_currency: "EUR", target_currency: nil, status: "outgoing_payment_sent",
                        reference: nil, rate: 1.0)
      {
        "id" => id,
        "targetAccount" => target_account,
        "sourceAccount" => nil,
        "sourceCurrency" => source_currency,
        "sourceValue" => source_value,
        "targetCurrency" => target_currency || source_currency,
        "targetValue" => target_value || source_value,
        "status" => status,
        "rate" => rate,
        "created" => "2026-01-15 10:00:00",
        "details" => reference ? { "reference" => reference } : {}
      }
    end
end
