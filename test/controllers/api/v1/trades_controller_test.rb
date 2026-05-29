# frozen_string_literal: true

require "test_helper"

class Api::V1::TradesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:family_admin)
    @family = @admin.family
    @investment = accounts(:investment)
    @security = securities(:aapl)

    @member = users(:family_member)
    @member.api_keys.active.destroy_all
    @member_key = ApiKey.create!(
      user: @member,
      name: "Member RW",
      scopes: [ "read_write" ],
      source: "web",
      display_key: "test_member_#{SecureRandom.hex(8)}"
    )
  end

  test "should not create trade on account without write permission" do
    assert_no_difference -> { Trade.count } do
      post api_v1_trades_url,
           params: {
             trade: {
               account_id: @investment.id,
               type: "buy",
               date: Date.current,
               qty: 1,
               price: 100,
               currency: "USD",
               security_id: @security.id
             }
           },
           headers: { "X-Api-Key" => @member_key.plain_key }
    end

    assert_response :not_found
  end
end
