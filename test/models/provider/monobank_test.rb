require "test_helper"

class Provider::MonobankTest < ActiveSupport::TestCase
  FakeResponse = Struct.new(:code, :body, :message, keyword_init: true)

  test "sends the personal token in X-Token and returns the statement window" do
    requests = []
    response = FakeResponse.new(
      code: 200,
      message: "OK",
      body: [ { id: "tx_1", time: 1_767_960_000, hold: false, amount: -4_000 } ].to_json
    )

    Provider::Monobank.stub(:get, ->(url, headers:, query: nil) {
      requests << { url: url, headers: headers }
      response
    }) do
      transactions = Provider::Monobank.new("mono-token").get_statement(
        account_id: "acc_1",
        from: Time.at(1_767_800_000),
        to: Time.at(1_767_960_000)
      )

      assert_equal [ "tx_1" ], transactions.map { |tx| tx[:id] }
      assert_equal [ "acc_1" ], transactions.map { |tx| tx[:account_id] }
    end

    assert_equal 1, requests.size
    assert_equal "https://api.monobank.ua/personal/statement/acc_1/1767800000/1767960000", requests.first[:url]
    assert_equal "mono-token", requests.first[:headers]["X-Token"]
  end

  # A statement is documented as a JSON array. A 204, an empty body or an error object
  # must not read as "no activity": the caller would record the window as permanently
  # covered and never ask again.
  test "rejects a statement response that is not an array" do
    [ "", "{\"errorDescription\":\"too many requests\"}" ].each do |body|
      Provider::Monobank.stub(:get, ->(_url, headers:, query: nil) {
        FakeResponse.new(code: 200, message: "OK", body: body)
      }) do
        error = assert_raises(Provider::Monobank::Error) do
          Provider::Monobank.new("mono-token").get_statement(
            account_id: "acc_1",
            from: Time.at(1_767_800_000),
            to: Time.at(1_767_960_000)
          )
        end

        assert_equal :parse_error, error.failure_code
      end
    end
  end

  test "refuses a window wider than Monobank's cap" do
    error = assert_raises(Provider::Monobank::Error) do
      Provider::Monobank.new("mono-token").get_statement(
        account_id: "acc_1",
        from: 40.days.ago,
        to: Time.current
      )
    end

    assert_equal :window_too_large, error.failure_code
  end
end
