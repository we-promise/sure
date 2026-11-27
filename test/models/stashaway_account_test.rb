require "test_helper"

class StashawayAccountTest < ActiveSupport::TestCase
  include StashawayTestHelper

  test "keeps the ids of the portfolios it holds, for matching them without their detail" do
    account = stashaway_accounts(:general)
    assert_equal [], account.goal_ids

    account.update!(raw_goals_payload: [ stashaway_goal("g1", transactions: []), stashaway_goal("g2", transactions: [], name: "Travel") ])

    assert_equal %w[g1 g2], account.reload.goal_ids
  end
end
