require "test_helper"

class WeeklyCleanup::DetectorsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
  end

  test "uncategorized transactions detector finds recent uncategorized standard transactions" do
    create_transaction(account: @account, name: "Mystery Store", date: 2.days.ago, amount: 42)
    categorized = create_transaction(account: @account, name: "Known Store", date: 1.day.ago, amount: 10)
    categorized.entryable.update!(category: categories(:food_and_drink))

    finding = WeeklyCleanup::Detectors::UncategorizedTransactions.new(@family).generate

    assert finding
    assert_equal "uncategorized_transactions", finding.key
    assert finding.count >= 1
    assert finding.samples.any? { |s| s.include?("Mystery Store") }
  end

  test "uncategorized detector ignores transfers and excluded entries" do
    create_transaction(account: @account, name: "Transfer Thing", date: 1.day.ago, amount: 50, kind: "funds_movement")
    excluded = create_transaction(account: @account, name: "Excluded Thing", date: 1.day.ago, amount: 50)
    excluded.update!(excluded: true)

    finding = WeeklyCleanup::Detectors::UncategorizedTransactions.new(@family).generate

    samples = finding ? finding.samples : []
    assert samples.none? { |s| s.include?("Transfer Thing") }
    assert samples.none? { |s| s.include?("Excluded Thing") }
  end

  test "missing merchant info detector finds merchantless transactions" do
    create_transaction(account: @account, name: "No Merchant Here", date: 1.day.ago, amount: 25)
    with_merchant = create_transaction(account: @account, name: "Has Merchant", date: 1.day.ago, amount: 25)
    with_merchant.entryable.update!(merchant: merchants(:netflix))

    finding = WeeklyCleanup::Detectors::MissingMerchantInfo.new(@family).generate

    assert finding
    assert finding.samples.any? { |s| s.include?("No Merchant Here") }
  end

  test "missing context detector only flags larger noteless attachment-free expenses" do
    big = create_transaction(account: @account, name: "Big Purchase", date: 1.day.ago, amount: 250)
    small = create_transaction(account: @account, name: "Small Purchase", date: 1.day.ago, amount: 20)
    noted = create_transaction(account: @account, name: "Noted Purchase", date: 1.day.ago, amount: 300, notes: "birthday gift")

    finding = WeeklyCleanup::Detectors::MissingContext.new(@family).generate

    assert finding
    assert finding.samples.any? { |s| s.include?("Big Purchase") }
    assert finding.samples.none? { |s| s.include?("Small Purchase") }
    assert finding.samples.none? { |s| s.include?("Noted Purchase") }
  end

  test "stale imports detector finds failed and stuck imports" do
    failed = imports(:transaction)
    failed.update!(status: "failed")
    stuck = imports(:trade)
    stuck.update!(status: "importing")
    stuck.update_column(:updated_at, (Import::STUCK_AFTER + 1.hour).ago)
    fresh = imports(:account) # importing but recent - not stale
    fresh.update!(status: "importing")

    finding = WeeklyCleanup::Detectors::StaleImports.new(@family).generate

    assert finding
    assert_equal 2, finding.count
  end

  test "duplicate imported entries detector groups same account/date/amount/name imports" do
    import = imports(:transaction)
    2.times do
      create_transaction(account: @account, name: "DUP CHARGE", date: 3.days.ago, amount: 9.99, import: import)
    end
    create_transaction(account: @account, name: "UNIQUE CHARGE", date: 3.days.ago, amount: 9.99, import: import)
    # not imported - manual entries should never count
    2.times { create_transaction(account: @account, name: "MANUAL SAME", date: 3.days.ago, amount: 5) }

    finding = WeeklyCleanup::Detectors::DuplicateImportedEntries.new(@family).generate

    assert finding
    assert finding.count >= 1
    assert finding.samples.any? { |s| s.include?("dup charge") }
  end

  test "merchant duplicates detector reports clusters with coverage" do
    @family.merchants.create!(name: "Whole Foods")
    @family.merchants.create!(name: "Whole Foods Market, Inc.")

    finding = WeeklyCleanup::Detectors::MerchantDuplicates.new(@family).generate

    assert finding
    assert finding.heading.include?("duplicate clusters")
    assert finding.count >= 1
  end

  test "merchant duplicates detector returns nil when no clusters" do
    quiet_family = Family.create!(name: "No Dup Family")
    assert_nil WeeklyCleanup::Detectors::MerchantDuplicates.new(quiet_family).generate
  end
end
