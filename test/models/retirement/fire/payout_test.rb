require "test_helper"

class Retirement::Fire::PayoutTest < ActiveSupport::TestCase
  Payout = Retirement::Fire::Payout

  test "monthly_for_life pays only from start_age" do
    p = Payout.new(kind: "state", shape: "monthly_for_life", tax_treatment: "custom_post_tax", start_age: 67, monthly_amount: 100)
    assert_equal 0, p.contribute_at(66)[:income]
    assert_equal 1200, p.contribute_at(67)[:income]
    assert_equal 1200, p.contribute_at(90)[:income]
    assert_equal 0, p.contribute_at(67)[:portfolio_delta]
  end

  test "monthly_fixed_term stops at end_age" do
    p = Payout.new(kind: "other", shape: "monthly_fixed_term", tax_treatment: "custom_post_tax", start_age: 60, end_age: 65, monthly_amount: 100)
    assert_equal 1200, p.contribute_at(60)[:income]
    assert_equal 1200, p.contribute_at(64)[:income]
    assert_equal 0, p.contribute_at(65)[:income]
  end

  test "lump_sum drops a one-time portfolio delta at start_age" do
    p = Payout.new(kind: "workplace", shape: "lump_sum", tax_treatment: "custom_post_tax", start_age: 65, monthly_amount: 30_000)
    assert_equal 0, p.contribute_at(65)[:income]
    assert_equal 30_000, p.contribute_at(65)[:portfolio_delta]
    assert_equal 0, p.contribute_at(66)[:portfolio_delta]
  end

  test "lump_plus_annuity pays annuity from start and lump once" do
    p = Payout.new(kind: "workplace", shape: "lump_plus_annuity", tax_treatment: "custom_post_tax", start_age: 65, monthly_amount: 620, lump_amount: 30_000)
    assert_equal 620 * 12, p.contribute_at(65)[:income]
    assert_equal 30_000, p.contribute_at(65)[:portfolio_delta]
    assert_equal 620 * 12, p.contribute_at(70)[:income]
    assert_equal 0, p.contribute_at(70)[:portfolio_delta]
  end
end
