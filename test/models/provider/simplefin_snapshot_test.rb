require "test_helper"
require "ostruct"

class Provider::SimplefinSnapshotTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Simplefin.new
    @url = "https://private-user:private-password@bridge.example/access"
  end

  test "native snapshot preserves exact JSON decimal tokens and requests pending only when enabled" do
    response = OpenStruct.new(code: 200, body: '{"accounts":[{"balance":1234567890123456.123456789012345678}]}')
    Provider::Simplefin.expects(:get).with("#{@url}/accounts?pending=1").returns(response)
    result = @provider.get_accounts_snapshot(@url, pending: true)
    assert_equal BigDecimal("1234567890123456.123456789012345678"), result.fetch(:accounts).first.fetch(:balance)
    assert_instance_of BigDecimal, result.fetch(:accounts).first.fetch(:balance)

    Provider::Simplefin.expects(:get).with("#{@url}/accounts").returns(OpenStruct.new(code: 200, body: '{"accounts":[]}'))
    assert_equal({ accounts: [] }, @provider.get_accounts_snapshot(@url, pending: false))
  end

  test "native snapshot encodes bounded dates without pending zero" do
    from = Time.utc(2026, 1, 1)
    through = Time.utc(2026, 1, 31)
    Provider::Simplefin.expects(:get).with("#{@url}/accounts?start-date=#{from.to_i}&end-date=#{through.to_i}")
      .returns(OpenStruct.new(code: 200, body: '{"accounts":[]}'))
    @provider.get_accounts_snapshot(@url, start_date: from, end_date: through, pending: false)
    assert_raises(ArgumentError) { @provider.get_accounts_snapshot(@url, start_date: from, end_date: from + 61.days, pending: false) }
    assert_raises(ArgumentError) { @provider.get_accounts_snapshot(@url, start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 4, 1), pending: false) }
  end

  test "transport failures redact access credentials and response bodies" do
    Provider::Simplefin.expects(:get).returns(OpenStruct.new(code: 403, body: 'private-password and sensitive response'))
    error = assert_raises(Provider::Simplefin::SimplefinError) { @provider.get_accounts_snapshot(@url, pending: true) }
    assert_equal :access_forbidden, error.error_type
    refute_includes error.message, "private-password"
    refute_includes error.message, "sensitive response"
    assert_nil error.cause

    Provider::Simplefin.expects(:get).times(4).raises(Net::ReadTimeout.new("request to #{@url} timed out"))
    @provider.stubs(:sleep)
    Rails.logger.expects(:warn).with { |message| !message.include?("private-password") }.times(3)
    Rails.logger.expects(:error).with { |message| !message.include?("private-password") }.once
    error = assert_raises(Provider::Simplefin::SimplefinError) { @provider.get_accounts_snapshot(@url, pending: false) }
    assert_equal :network_error, error.error_type
    refute_includes error.message, "private-password"
    assert_nil error.cause
  end
end
