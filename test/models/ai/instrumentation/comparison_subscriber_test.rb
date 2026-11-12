require "test_helper"

# The subscriber swallows everything deliberately — a diagnostic must never break the
# job that observes it — and a row whose subject_id isn't a uuid is unreadable
# telemetry, so it is dropped with a log naming the family, never inserted.
class Ai::Instrumentation::ComparisonSubscriberTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "a payload whose subject ids are not uuids is dropped with a log naming the family" do
    payload = {
      feature: "categorize", family_id: @family.id, subject_type: "Transaction",
      primary: { route: { endpoint: "openai", model: "gpt-4.1-mini" }, values: { "t_garbage" => [ "Coffee", nil ] } },
      shadow: { route: { endpoint: "jev", model: "jev-latest" }, values: { "t_garbage" => [ "Coffee", 0.9 ] } }
    }
    Rails.logger.expects(:error).with(regexp_matches(/dropped 1 comparison\(s\).*family_id=#{@family.id}/))

    Ai::Instrumentation::ComparisonSubscriber.new.call(event(payload))

    assert_equal 0, Ai::Comparison.count
  end

  test "a well-formed payload inserts one row per id, agreeing when the answers match" do
    uuid = SecureRandom.uuid
    payload = {
      feature: "categorize", family_id: @family.id, subject_type: "Transaction",
      primary: { route: { endpoint: "openai", model: "gpt-4.1-mini" }, values: { uuid => [ "Coffee", nil ] } },
      shadow: { route: { endpoint: "jev", model: "jev-latest" }, values: { uuid => [ "Coffee", 0.9 ] } }
    }

    Ai::Instrumentation::ComparisonSubscriber.new.call(event(payload))

    comparison = Ai::Comparison.sole
    assert_equal "categorize", comparison.feature
    assert_equal true, comparison.agreed
    assert_equal uuid, comparison.subject_id
  end

  private
    def event(payload)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ActiveSupport::Notifications::Event.new("compare.ai_shadow", now - 0.1, now, SecureRandom.hex(4), payload)
    end
end
