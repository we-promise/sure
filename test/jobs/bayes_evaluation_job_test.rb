require "test_helper"

class BayesEvaluationJobTest < ActiveJob::TestCase
  test "runs the evaluation and replaces the page's results panel" do
    family = families(:empty)
    evaluation = { "digest" => family.bayes_settings_object.digest }
    Family::BayesEvaluation.any_instance.expects(:run!).returns(evaluation)
    Turbo::StreamsChannel.expects(:broadcast_replace_to).with do |*args|
      options = args.last
      args.first == family && options[:target] == "classifier_evaluation" && options[:locals][:evaluation] == evaluation
    end

    BayesEvaluationJob.perform_now(family)
  end

  test "a failed run puts the panel back on the last result and still raises" do
    family = families(:empty)
    cached = { "digest" => "earlier" }
    Family::BayesEvaluation.stubs(:cached).with(family).returns(cached)
    Family::BayesEvaluation.any_instance.expects(:run!).raises(ActiveRecord::QueryCanceled)
    Turbo::StreamsChannel.expects(:broadcast_replace_to).with do |*args|
      options = args.last
      options[:target] == "classifier_evaluation" && options[:locals][:evaluation] == cached && options[:locals][:running] == false
    end

    assert_raises(ActiveRecord::QueryCanceled) { BayesEvaluationJob.perform_now(family) }
  end

  test "a search shows each change it tries" do
    family = families(:empty)
    Family::BayesEvaluation.any_instance.expects(:run!).with(action: "find_best").multiple_yields([ { binary: true } ], [ { smoothing: 0.1 } ], [ { word_split: "unicode", amount_field: true } ]).returns({})
    Turbo::StreamsChannel.expects(:broadcast_update_to).with(family, target: "classifier_evaluation_progress", html: "Trying Exclude repeated words: on…")
    Turbo::StreamsChannel.expects(:broadcast_update_to).with(family, target: "classifier_evaluation_progress", html: "Trying Smoothing: 0.1…")
    Turbo::StreamsChannel.expects(:broadcast_update_to).with(family, target: "classifier_evaluation_progress", html: "Trying Words are made of: Letters and digits, any script; Include the amount: on…")
    Turbo::StreamsChannel.expects(:broadcast_replace_to)

    BayesEvaluationJob.perform_now(family, action: "find_best")
  end
end
