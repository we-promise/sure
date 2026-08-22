require "test_helper"

class Provider::SentryAiMonitoringTest < ActiveSupport::TestCase
  test "telemetry identifiers are stable keyed HMACs" do
    identifier = "48e35936-82ab-4f1a-beaf-b2fa4273ac5e"

    first = Provider::SentryAiMonitoring.send(
      :telemetry_identifier,
      "conversation",
      identifier
    )
    second = Provider::SentryAiMonitoring.send(
      :telemetry_identifier,
      "conversation",
      identifier
    )
    user_scoped = Provider::SentryAiMonitoring.send(
      :telemetry_identifier,
      "user",
      identifier
    )

    assert_equal first, second
    assert_not_equal identifier, first
    assert_not_equal user_scoped, first
    assert_match(/\A\h{64}\z/, first)
  end
end
