require "test_helper"

class WeeklyCleanup::MerchantDedupTest < ActiveSupport::TestCase
  MerchantStub = Data.define(:name)

  test "normalizes case, punctuation, business suffixes, and store numbers" do
    assert_equal "whole foods", WeeklyCleanup::MerchantDedup.normalize("Whole Foods, Inc.")
    assert_equal "target", WeeklyCleanup::MerchantDedup.normalize("TARGET #1234")
    assert_equal "at and t", WeeklyCleanup::MerchantDedup.normalize("AT&T")
    assert_equal "shell", WeeklyCleanup::MerchantDedup.normalize("Shell LLC")
  end

  test "clusters obvious duplicates and reports coverage" do
    merchants = [
      "Whole Foods", "Whole Foods Market, Inc.", "WHOLE FOODS #512",
      "Netflix", "Netflix.com",
      "Shell", "Chevron", "Trader Joe's"
    ].map { |n| MerchantStub.new(n) }

    result = WeeklyCleanup::MerchantDedup.call(merchants)

    assert_equal 8, result.total
    cluster_sets = result.clusters.map { |c| c.members.map(&:name).sort }
    assert cluster_sets.any? { |s| s.include?("Whole Foods") && s.include?("WHOLE FOODS #512") }
    assert cluster_sets.any? { |s| s.include?("Netflix") && s.include?("Netflix.com") }
    # Distinct brands never cluster together
    assert cluster_sets.flatten.none? { |n| n == "Shell" && cluster_sets.any? { |s| s.include?("Chevron") && s.include?("Shell") } }
    assert_equal result.clustered, result.clusters.sum { |c| c.members.size }
    assert result.coverage_pct > 0
  end

  test "handles empty input" do
    result = WeeklyCleanup::MerchantDedup.call([])
    assert_equal 0, result.total
    assert_equal 0, result.coverage_pct
    assert_empty result.clusters
  end

  test "does not cluster unrelated short names" do
    merchants = [ "Apple", "Applebees", "Amazon" ].map { |n| MerchantStub.new(n) }
    result = WeeklyCleanup::MerchantDedup.call(merchants)
    assert_empty result.clusters
  end
end
