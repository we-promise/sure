require "test_helper"

class Api::V1::TransactionTimestampsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @entry = entries(:transaction)
    @key = ApiKey.create!(user: users(:family_admin), name: "Timestamp test",
      key: ApiKey.generate_secure_key, scopes: [ "read" ], source: "web")
  end

  test "read API returns UTC occurrence time independently from accounting date" do
    @entry.update!(date: "2026-09-18", transacted_at: Time.iso8601("2026-09-17T14:48:50.123456Z"))
    get api_v1_transaction_url(@entry.transaction), headers: api_headers(@key)
    assert_response :success
    data = response.parsed_body
    assert_equal "2026-09-18", data.fetch("date")
    assert_equal "2026-09-17T14:48:50.123456Z", data.fetch("transacted_at")
  end

  test "date-only entries return null rather than an invented midnight" do
    get api_v1_transaction_url(@entry.transaction), headers: api_headers(@key)
    assert_response :success
    assert response.parsed_body.key?("transacted_at")
    assert_nil response.parsed_body["transacted_at"]
  end
end
