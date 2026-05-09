require "test_helper"

class Provider::ConsentExpiryCheckJobTest < ActiveJob::TestCase
  test "marks connection as requires_update when consent expires within 7 days" do
    connection = provider_connections(:monzo_connection)
    connection.update!(
      status: :healthy,
      metadata: { "consent_expires_at" => 3.days.from_now.iso8601 }
    )

    Provider::ConsentExpiryCheckJob.perform_now

    connection.reload
    assert_equal "requires_update", connection.status
    assert_equal "consent_expiring", connection.read_attribute(:sync_error)
  end

  test "leaves connection as healthy when consent expires beyond 7 days" do
    connection = provider_connections(:monzo_connection)
    connection.update!(
      status: :healthy,
      metadata: { "consent_expires_at" => 30.days.from_now.iso8601 }
    )

    Provider::ConsentExpiryCheckJob.perform_now

    connection.reload
    assert_equal "healthy", connection.status
  end

  test "leaves connection as healthy when metadata has no consent_expires_at" do
    connection = provider_connections(:monzo_connection)
    connection.update!(
      status: :healthy,
      metadata: {}
    )

    Provider::ConsentExpiryCheckJob.perform_now

    connection.reload
    assert_equal "healthy", connection.status
  end

  test "does not process connections already in requires_update" do
    connection = provider_connections(:monzo_connection)
    connection.update!(
      status: :requires_update,
      metadata: { "consent_expires_at" => 1.day.from_now.iso8601 }
    )

    Provider::ConsentExpiryCheckJob.perform_now

    connection.reload
    assert_equal "requires_update", connection.status
  end
end
