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
    %w[brokerage cash_management mutual_fund angel trust ugma utma other].each do |subtype|
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
    valid_regions = [ *Investment::REGIONS, nil ]

    Investment::SUBTYPES.each do |key, metadata|
      assert_includes valid_regions, metadata[:region],
        "Subtype #{key} has invalid region: #{metadata[:region]}"
    end
  end

  # India account types

  test "India pension subtypes have tax_advantaged treatment" do
    %w[nps apy epf].each do |subtype|
      investment = Investment.new(subtype: subtype)
      assert_equal :tax_advantaged, investment.tax_treatment, "Expected #{subtype} to be tax_advantaged"
    end
  end

  test "EPF is an India subtype available to INR users" do
    assert_equal "in", Investment::SUBTYPES.dig("epf", :region)
    assert_equal "Employees' Provident Fund", Investment::SUBTYPES.dig("epf", :long)

    india_group = Investment.subtypes_grouped_for_select(country: "IN").first[1]
    assert_includes india_group.map(&:last), "epf"
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

  test "subtypes_grouped_for_select places the family's country first" do
    grouped = Investment.subtypes_grouped_for_select(country: "IN")
    assert_equal I18n.t("accounts.subtype_regions.in"), grouped.first[0]
    assert_equal I18n.t("accounts.subtype_regions.generic"), grouped.second[0]
  end

  test "subtypes_grouped_for_select maps GB to the UK group" do
    grouped = Investment.subtypes_grouped_for_select(country: "GB")
    assert_equal I18n.t("accounts.subtype_regions.uk"), grouped.first[0]
  end

  test "subtypes_grouped_for_select limits country groups but always shows General" do
    labels = Investment.subtypes_grouped_for_select(country: "SE", regions: [ "se" ]).map(&:first)

    assert_equal [ "accounts.subtype_regions.se", "accounts.subtype_regions.generic" ].map { |key| I18n.t(key) }, labels
  end

  test "subtypes_grouped_for_select keeps the selected subtype's group visible" do
    grouped = Investment.subtypes_grouped_for_select(country: "SE", regions: [ "se" ], selected: "pea")

    assert_includes grouped.flat_map { |_, options| options.map(&:last) }, "pea"
  end

  # Regional account types

  test "French, German and Swiss subtypes sit in their own country groups" do
    assert_equal "fr", Investment::SUBTYPES.dig("assurance_vie", :region)
    assert_equal "fr", Investment::SUBTYPES.dig("pea", :region)
    assert_equal "de", Investment::SUBTYPES.dig("riester", :region)
    assert_equal "ch", Investment::SUBTYPES.dig("pillar_3a", :region)
  end

  test "Swedish subtypes have the expected tax treatment" do
    expected = {
      "isk" => :tax_advantaged, "kapitalforsakring" => :tax_advantaged, "aktie_och_fondkonto" => :taxable,
      "tjanstepension" => :tax_deferred, "premiepension" => :tax_deferred, "ips" => :tax_deferred,
      "pensionsforsakring" => :tax_deferred
    }

    expected.each do |subtype, treatment|
      assert_equal "se", Investment::SUBTYPES.dig(subtype, :region)
      assert_equal treatment, Investment.new(subtype: subtype).tax_treatment, "Expected #{subtype} to be #{treatment}"
    end
  end

  test "brokerage is a General subtype" do
    assert_nil Investment::SUBTYPES.dig("brokerage", :region)
  end

  test "default regions follow the country, or include every region for countries without their own" do
    assert_equal [ "se" ], Investment.default_regions_for_country("SE")
    assert_equal [ "uk" ], Investment.default_regions_for_country("GB")
    assert_equal Investment::REGIONS, Investment.default_regions_for_country("JP")
  end

  test "every region has a label" do
    [ *Investment::REGIONS, nil ].each do |region|
      assert_not_includes Investment.region_label_for(region), "Translation missing"
    end
  end
end
