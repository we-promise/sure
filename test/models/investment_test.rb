require "test_helper"

class InvestmentTest < ActiveSupport::TestCase
  test "digital gold remains valid when it has existing holdings" do
    account = accounts(:investment)
    investment = account.investment

    investment.update!(subtype: "gold", gold_form: "digital")

    assert investment.valid?
    assert account.supports_trades?
  end

  test "calculates physical gold value from weight, purity, and a troy-ounce quote" do
    investment = Investment.new(subtype: "gold", gold_weight: 100, gold_weight_unit: "gram", gold_karat: 18)

    assert_in_delta 7_500, investment.gold_value_for(3_110.34768), 0.01
  end

  test "rejects physical gold details on a non-gold investment" do
    investment = Investment.new(subtype: "brokerage", gold_weight: 10, gold_weight_unit: "gram", gold_karat: 24, gold_manual_value: 500)

    assert_not investment.valid?
    assert_includes investment.errors.full_messages, "Physical gold details require the Physical gold form."
  end

  test "uses a manual gold valuation override when present" do
    investment = Investment.new(subtype: "gold", gold_manual_value: 12_345)

    assert_equal 12_345, investment.gold_value_for(3_000)
  end

  test "treats Gold as digital when selected and clears physical details" do
    investment = Investment.new(subtype: "gold", gold_form: "digital", gold_weight: 1, gold_weight_unit: "gram", gold_karat: 24)

    assert investment.digital_gold?
    assert investment.valid?
    assert_nil investment.gold_weight
    assert_nil investment.gold_karat
  end

  test "refuses conversion to digital gold while physical purchases exist" do
    account = accounts(:investment)
    account.holdings.destroy_all
    investment = account.investment
    investment.update!(subtype: "gold", gold_form: "physical")
    account.physical_gold_lots.create!(description: "Coin", acquired_on: Date.current, weight: 10, weight_unit: "gram", karat: 24, cost_amount: 1_000)

    investment.gold_form = "digital"

    assert_not investment.valid?
    assert_includes investment.errors[:gold_form], "cannot be changed to Digital gold while physical gold purchases exist."
  end

  test "clears gold form when converting to another investment subtype" do
    investment = Investment.new(subtype: "gold", gold_form: "physical")

    investment.subtype = "brokerage"

    assert investment.valid?
    assert_nil investment.gold_form
  end

  # Tax treatment derivation tests

  test "tax_treatment returns tax_deferred for US retirement accounts" do
    %w[401k 403b 457b tsp ira sep_ira simple_ira].each do |subtype|
      investment = Investment.new(subtype: subtype)
      assert_equal :tax_deferred, investment.tax_treatment, "Expected #{subtype} to be tax_deferred"
    end
  end

  test "tax_treatment returns tax_exempt for Roth accounts" do
    %w[roth_401k roth_ira].each do |subtype|
      investment = Investment.new(subtype: subtype)
      assert_equal :tax_exempt, investment.tax_treatment, "Expected #{subtype} to be tax_exempt"
    end
  end

  test "tax_treatment returns tax_advantaged for special accounts" do
    %w[529_plan hsa].each do |subtype|
      investment = Investment.new(subtype: subtype)
      assert_equal :tax_advantaged, investment.tax_treatment, "Expected #{subtype} to be tax_advantaged"
    end
  end

  test "tax_treatment returns taxable for standard accounts" do
    %w[brokerage mutual_fund angel trust ugma utma other].each do |subtype|
      investment = Investment.new(subtype: subtype)
      assert_equal :taxable, investment.tax_treatment, "Expected #{subtype} to be taxable"
    end
  end

  test "tax_treatment returns taxable for nil subtype" do
    investment = Investment.new(subtype: nil)
    assert_equal :taxable, investment.tax_treatment
  end

  test "tax_treatment returns taxable for unknown subtype" do
    investment = Investment.new(subtype: "unknown_type")
    assert_equal :taxable, investment.tax_treatment
  end

  # UK account types

  test "tax_treatment returns tax_exempt for UK ISA accounts" do
    %w[isa lisa].each do |subtype|
      investment = Investment.new(subtype: subtype)
      assert_equal :tax_exempt, investment.tax_treatment, "Expected #{subtype} to be tax_exempt"
    end
  end

  test "tax_treatment returns tax_deferred for UK pension accounts" do
    %w[sipp workplace_pension_uk].each do |subtype|
      investment = Investment.new(subtype: subtype)
      assert_equal :tax_deferred, investment.tax_treatment, "Expected #{subtype} to be tax_deferred"
    end
  end

  # Canadian account types

  test "tax_treatment returns tax_deferred for Canadian retirement accounts" do
    %w[rrsp lira rrif].each do |subtype|
      investment = Investment.new(subtype: subtype)
      assert_equal :tax_deferred, investment.tax_treatment, "Expected #{subtype} to be tax_deferred"
    end
  end

  test "tax_treatment returns tax_exempt for Canadian TFSA" do
    investment = Investment.new(subtype: "tfsa")
    assert_equal :tax_exempt, investment.tax_treatment
  end

  test "tax_treatment returns tax_advantaged for Canadian RESP" do
    investment = Investment.new(subtype: "resp")
    assert_equal :tax_advantaged, investment.tax_treatment
  end

  # Australian account types

  test "tax_treatment returns tax_deferred for Australian super accounts" do
    %w[super smsf].each do |subtype|
      investment = Investment.new(subtype: subtype)
      assert_equal :tax_deferred, investment.tax_treatment, "Expected #{subtype} to be tax_deferred"
    end
  end

  # European account types

  test "tax_treatment returns tax_deferred for European pension accounts" do
    %w[pillar_3a riester].each do |subtype|
      investment = Investment.new(subtype: subtype)
      assert_equal :tax_deferred, investment.tax_treatment, "Expected #{subtype} to be tax_deferred"
    end
  end

  test "tax_treatment returns tax_advantaged for French PEA" do
    investment = Investment.new(subtype: "pea")
    assert_equal :tax_advantaged, investment.tax_treatment
  end

  test "tax_treatment returns tax_advantaged for French AV" do
    investment = Investment.new(subtype: "assurance_vie")
    assert_equal :tax_advantaged, investment.tax_treatment
  end
  # Generic account types

  test "tax_treatment returns tax_deferred for generic pension and retirement" do
    %w[pension retirement].each do |subtype|
      investment = Investment.new(subtype: subtype)
      assert_equal :tax_deferred, investment.tax_treatment, "Expected #{subtype} to be tax_deferred"
    end
  end

  # Subtype metadata tests

  test "all subtypes have required metadata keys" do
    Investment::SUBTYPES.each do |key, metadata|
      assert metadata.key?(:short), "Subtype #{key} missing :short key"
      assert metadata.key?(:long), "Subtype #{key} missing :long key"
      assert metadata.key?(:tax_treatment), "Subtype #{key} missing :tax_treatment key"
      assert metadata.key?(:region), "Subtype #{key} missing :region key"
    end
  end

  test "all subtypes have valid tax_treatment values" do
    valid_treatments = %i[taxable tax_deferred tax_exempt tax_advantaged]

    Investment::SUBTYPES.each do |key, metadata|
      assert_includes valid_treatments, metadata[:tax_treatment],
        "Subtype #{key} has invalid tax_treatment: #{metadata[:tax_treatment]}"
    end
  end

  test "all subtypes have valid region values" do
    valid_regions = [ "us", "uk", "ca", "au", "eu", "in", nil ]

    Investment::SUBTYPES.each do |key, metadata|
      assert_includes valid_regions, metadata[:region],
        "Subtype #{key} has invalid region: #{metadata[:region]}"
    end
  end

  # India account types

  test "India pension subtypes have tax_advantaged treatment" do
    %w[nps apy].each do |subtype|
      investment = Investment.new(subtype: subtype)
      assert_equal :tax_advantaged, investment.tax_treatment, "Expected #{subtype} to be tax_advantaged"
    end
  end

  test "India equity subtypes are taxable" do
    %w[indian_stocks indian_equity indian_etf].each do |subtype|
      investment = Investment.new(subtype: subtype)
      assert_equal :taxable, investment.tax_treatment, "Expected #{subtype} to be taxable"
    end
  end

  test "life insurance is tax_advantaged" do
    investment = Investment.new(subtype: "life_insurance")
    assert_equal :tax_advantaged, investment.tax_treatment
  end

  test "India subtypes all belong to the 'in' region" do
    india_keys = Investment::SUBTYPES.keys.select { |k| Investment::SUBTYPES.dig(k, :region) == "in" }
    assert india_keys.any?, "Expected at least one India subtype"
    india_keys.each do |key|
      assert_equal "in", Investment::SUBTYPES.dig(key, :region), "Expected #{key} to have region 'in'"
    end
  end

  test "subtypes_grouped_for_select places India region first for INR users" do
    grouped = Investment.subtypes_grouped_for_select(currency: "INR")
    assert grouped.any?, "grouped should not be empty"
    first_group_label = grouped.first[0]
    assert_equal I18n.t("accounts.subtype_regions.in"), first_group_label
  end
end
