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

  test "uses status-based fallback when no recipient_id stored" do
    @wise_account.update!(raw_payload: { "type" => "STANDARD" })

    outgoing = build_transfer(id: 1003, target_account: 9999, source_value: 100.0,
                               status: "outgoing_payment_sent")
    entry = WiseEntry::Processor.new(outgoing, wise_account: @wise_account).process
    assert entry.amount.positive?

    incoming = build_transfer(id: 1004, target_account: 9999, source_value: 100.0,
                               status: "funds_credited")
    entry = WiseEntry::Processor.new(incoming, wise_account: @wise_account).process
    assert entry.amount.negative?
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

  test "creates separate fee entry when sourceValue exceeds targetValue in same currency" do
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

  test "does not create fee entry for cross-currency transfers" do
    transfer = build_transfer(id: 4003, target_account: 9999, source_value: 100.0, target_value: 90.0,
                               source_currency: "EUR", target_currency: "GBP")

    WiseEntry::Processor.new(transfer, wise_account: @wise_account).process

    assert_equal 1, @account.entries.where(source: "wise").count
  end

  test "re-importing a transfer drops wise metadata Wise no longer reports" do
    WiseEntry::Processor.new(build_transfer(id: 4004, target_account: 9999, source_value: 100.5, target_value: 100.0),
                             wise_account: @wise_account).process

    entry = WiseEntry::Processor.new(build_transfer(id: 4004, target_account: 9999, source_value: 100.0, target_value: 100.0),
                                     wise_account: @wise_account).process

    assert_nil entry.entryable.reload.extra.dig("wise", "fee")
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
    transfer = build_transfer(id: 6001, target_account: 9999, source_value: 1828.25,
                              target_value: 1372.47, source_currency: "CAD",
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

    # Time.parse reads a zone-less string in the process time zone (ENV["TZ"]).
    def with_server_time_zone(zone)
      previous = ENV["TZ"]
      ENV["TZ"] = zone
      yield
    ensure
      ENV["TZ"] = previous
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
