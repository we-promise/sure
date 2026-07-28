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

    def build_transfer(id:, target_account:, source_value: 100.0, target_value: nil,
                        source_currency: "EUR", target_currency: nil, status: "outgoing_payment_sent",
                        reference: nil)
      {
        "id" => id,
        "targetAccount" => target_account,
        "sourceAccount" => nil,
        "sourceCurrency" => source_currency,
        "sourceValue" => source_value,
        "targetCurrency" => target_currency || source_currency,
        "targetValue" => target_value || source_value,
        "status" => status,
        "rate" => 1.0,
        "created" => "2026-01-15 10:00:00",
        "details" => reference ? { "reference" => reference } : {}
      }
    end
end
