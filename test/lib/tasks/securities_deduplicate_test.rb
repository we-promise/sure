# frozen_string_literal: true

require "test_helper"
require "rake"

RakeTaskTestHelper.load_task("securities:deduplicate", "securities")

class SecuritiesDeduplicateTest < ActiveSupport::TestCase
  setup do
    RakeTaskTestHelper.prepare("securities:deduplicate")
  end

  # A family's tags on a duplicate are moved like its holdings, trades and
  # prices, rather than destroyed with it.
  test "merging a duplicate without a MIC keeps its tags on the canonical security" do
    canonical = securities(:aapl)
    duplicate = Security.create!(ticker: "AAPL", exchange_operating_mic: nil, name: "Apple duplicate")
    duplicate.taggings.create!(tag: tags(:one))

    capture_io { Rake::Task["securities:deduplicate"].invoke }

    assert_not Security.exists?(duplicate.id)
    assert_equal [ tags(:one) ], canonical.tags_for(families(:dylan_family)).to_a
  end
end
