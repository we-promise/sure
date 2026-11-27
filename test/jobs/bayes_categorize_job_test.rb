require "test_helper"

class BayesCategorizeJobTest < ActiveJob::TestCase
  setup do
    @family = families(:empty)
  end

  test "Run fills merchants while the matcher's rule is on, then runs Bayes" do
    @family.stubs(:classifier_rule_active?).with("fill_similar_merchants").returns(true)
    sequence = sequence("run")
    @family.expects(:fill_similar_merchants).in_sequence(sequence)
    @family.expects(:bayes_categorize_uncategorized).in_sequence(sequence)

    BayesCategorizeJob.perform_now(@family)
  end

  test "Run skips the matcher while its rule is off" do
    @family.stubs(:classifier_rule_active?).with("fill_similar_merchants").returns(false)
    @family.expects(:fill_similar_merchants).never
    @family.expects(:bayes_categorize_uncategorized)

    BayesCategorizeJob.perform_now(@family)
  end
end
