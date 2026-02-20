require "test_helper"

class InvestmentTest < ActiveSupport::TestCase
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

  # French account types

  test "tax_treatment returns tax_exempt for French regulated savings accounts" do
    %w[livret_a ldds lep livret_jeune].each do |subtype|
      investment = Investment.new(subtype: subtype)
      assert_equal :tax_exempt, investment.tax_treatment, "Expected #{subtype} to be tax_exempt"
    end
  end

  test "tax_treatment returns tax_advantaged for French tax-advantaged plans" do
    %w[assurance_vie contrat_de_capitalisation pee peg pel].each do |subtype|
      investment = Investment.new(subtype: subtype)
      assert_equal :tax_advantaged, investment.tax_treatment, "Expected #{subtype} to be tax_advantaged"
    end
  end

  test "tax_treatment returns tax_deferred for French retirement plans" do
    %w[per per_individuel per_collectif per_obligatoire].each do |subtype|
      investment = Investment.new(subtype: subtype)
      assert_equal :tax_deferred, investment.tax_treatment, "Expected #{subtype} to be tax_deferred"
    end
  end

  test "tax_treatment returns taxable for French taxable accounts" do
    %w[cto lee].each do |subtype|
      investment = Investment.new(subtype: subtype)
      assert_equal :taxable, investment.tax_treatment, "Expected #{subtype} to be taxable"
    end
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
    valid_regions = [ "us", "uk", "ca", "au", "eu", "fr", nil ]

    Investment::SUBTYPES.each do |key, metadata|
      assert_includes valid_regions, metadata[:region],
        "Subtype #{key} has invalid region: #{metadata[:region]}"
    end
  end

  test "subtypes_grouped_for_select includes France region" do
    grouped = Investment.subtypes_grouped_for_select(currency: "EUR")
    labels = grouped.map(&:first)

    assert_includes labels, I18n.t("accounts.subtype_regions.fr")
  end
end
