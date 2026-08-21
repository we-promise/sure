require "test_helper"

class YaxiTicketTest < ActiveSupport::TestCase
  test "does not persist a ticket when signing fails" do
    provider = OpenStruct.new
    provider.define_singleton_method(:issue_ticket) do |**|
      raise Provider::Yaxi::InvalidConfigurationError, "signing failed"
    end
    Provider::YaxiAdapter.stubs(:build_provider).returns(provider)
    user = users(:family_member)

    assert_no_difference "YaxiTicket.count" do
      assert_raises(Provider::Yaxi::InvalidConfigurationError) do
        YaxiTicket.issue!(family: user.family, user: user, service: "Accounts")
      end
    end
  end

  test "tickets are removed when their user is destroyed" do
    user = users(:family_member)
    user.yaxi_tickets.create!(
      family: user.family,
      service: "Accounts",
      expires_at: 5.minutes.from_now
    )

    assert_difference "YaxiTicket.count", -1 do
      user.purge
    end
  end
end
