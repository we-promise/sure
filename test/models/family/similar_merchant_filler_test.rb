require "test_helper"

class Family::SimilarMerchantFillerTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = Family.create!(name: "Merchant fill family")
    @account = @family.accounts.create!(name: "Merchant fill", balance: 0, currency: "USD", accountable: Depository.new)
    @netflix = @family.merchants.create!(name: "Netflix")
    @hulu = @family.merchants.create!(name: "Hulu")
  end

  def transaction(name, **attributes)
    create_transaction(account: @account, name: name, **attributes).transaction
  end

  # A copy the matcher made and locked itself.
  def fill_from_hulu(transaction)
    transaction.enrich_attribute(:merchant_id, @hulu.id, source: "similar", metadata: { locked_by_similar: true })
    transaction.lock_attr!(:merchant_id)
  end

  def fill(*transactions, **settings)
    Family::SimilarMerchantFiller.new(@family, settings: Family::BayesSettings.new(settings)).fill(transactions.map(&:id))
  end

  test "copies the merchant two near-duplicates agree on, as a similar enrichment" do
    2.times { transaction("NETFLIX.COM 8812", merchant: @netflix) }
    missing = transaction("Netflix com 1203")

    assert_equal 1, fill(missing)
    assert_equal @netflix.id, missing.reload.merchant_id
    assert_equal "similar", missing.data_enrichments.find_by(attribute_name: "merchant_id").source
  end

  test "leaves it alone with one near-duplicate, a disagreement or a lock" do
    transaction("NETFLIX.COM 8812", merchant: @netflix)
    missing = transaction("Netflix com 1203")

    assert_equal 0, fill(missing)

    transaction("Netflix com", merchant: @hulu)
    transaction("NETFLIX COM", merchant: @netflix)
    assert_equal 0, fill(missing)

    locked = transaction("Hulu LLC")
    locked.lock_attr!(:merchant_id)
    2.times { transaction("HULU LLC", merchant: @hulu) }
    assert_equal 0, fill(locked)
    assert_nil locked.reload.merchant_id
  end

  test "an AI merchant is copied, but not its own unconfirmed copy" do
    2.times { transaction("NETFLIX.COM 8812").tap { |t| t.enrich_attribute(:merchant_id, @netflix.id, source: "ai") } }
    missing = transaction("Netflix com 1203")

    assert_equal 1, fill(missing)

    copies = Array.new(2) { transaction("HULU LLC 77").tap { |t| t.enrich_attribute(:merchant_id, @hulu.id, source: "similar") } }
    hulu = transaction("Hulu LLC 12")
    assert_equal 0, fill(hulu)

    copies.each { |copy| copy.lock_attr!(:merchant_id) }
    assert_equal 1, fill(hulu)
  end

  test "with lock_similar_merchants it locks what it fills, without that counting as confirmed" do
    2.times { transaction("NETFLIX.COM 8812", merchant: @netflix) }
    missing = transaction("Netflix com 1203")

    assert_equal 1, fill(missing, lock_similar_merchants: true)
    assert missing.reload.locked?(:merchant_id)
    assert missing.data_enrichments.find_by(attribute_name: "merchant_id").metadata["locked_by_similar"]

    copies = Array.new(2) { transaction("Hulu LLC 77").tap { |t| fill_from_hulu(t) } }
    assert copies.all? { |copy| copy.reload.locked?(:merchant_id) }
    assert_equal 0, fill(transaction("HULU LLC 12"))
  end

  test "its own copies count when that check is off" do
    2.times { transaction("HULU LLC 77").tap { |t| t.enrich_attribute(:merchant_id, @hulu.id, source: "similar") } }
    assert_equal 1, fill(transaction("Hulu LLC 12"), similar_skip_self: false)
  end

  test "transfers neither give nor get merchants" do
    bank = @family.merchants.create!(name: "CBA")
    2.times { transaction("Savings top-up", merchant: bank, kind: "funds_movement") }
    transfer = transaction("Savings top up", kind: "funds_movement")
    missing = transaction("Savings top-up")

    assert_equal 0, fill(transfer, missing)
  end

  test "the family fills only the missing merchants in scope, and Bayes fills none" do
    2.times { transaction("NETFLIX.COM 8812", merchant: @netflix) }
    missing = transaction("Netflix com 1203")
    elsewhere = transaction("Netflix com 5531")

    @family.bayes_categorize_uncategorized
    assert_nil missing.reload.merchant_id

    assert_equal 1, @family.fill_similar_merchants(@family.transactions.where(id: missing.id))
    assert_equal @netflix.id, missing.reload.merchant_id
    assert_nil elsewhere.reload.merchant_id
  end
end
