require "test_helper"

class Provider::BrandfetchTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Brandfetch.new("test-brandfetch-key")
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
  end

  test "fetches billing-period credits with bearer authentication and caches by key" do
    request = stub_request(:get, "https://api.brandfetch.io/v2/viewer")
      .with(headers: { "Authorization" => "Bearer test-brandfetch-key" })
      .to_return(status: 200, body: { type: "api-key", usage: { used: 2, quota: 800 } }.to_json)
    2.times do
      response = @provider.usage
      assert response.success?
      assert_equal 2, response.data.used
      assert_equal 800, response.data.quota
      assert_equal 0.25, response.data.utilization
    end
    assert_requested request, times: 1

    other = stub_request(:get, "https://api.brandfetch.io/v2/viewer")
      .with(headers: { "Authorization" => "Bearer another-key" })
      .to_return(status: 200, body: { type: "api-key", usage: { used: 7, quota: 10 } }.to_json)
    assert_equal 7, Provider::Brandfetch.new("another-key").usage.data.used
    assert_requested other, times: 1
  end

  test "zero quota does not divide by zero or invent a percentage" do
    stub_viewer(type: "api-key", usage: { used: 0, quota: 0 })
    result = @provider.usage
    assert result.success?
    assert_nil result.data.utilization
    assert_nil result.data.bar_percentage
  end

  test "over-quota usage retains actual count while bounding progress bar" do
    stub_viewer(type: "api-key", usage: { used: 120, quota: 100 })
    result = @provider.usage
    assert_equal 120, result.data.used
    assert_equal 120, result.data.utilization
    assert_equal 100, result.data.bar_percentage
  end

  test "missing or malformed usage never appears as zero usage" do
    [ { type: "user" }, { type: "api-key", usage: { used: "2", quota: 800 } },
      { type: "api-key", usage: { used: -1, quota: 800 } } ].each do |body|
      stub_viewer(body)
      assert_not @provider.usage.success?
    end
  end

  test "authentication failures and timeouts return unavailable without upstream details" do
    request = stub_request(:get, "https://api.brandfetch.io/v2/viewer")
    request.to_return(status: 403, body: "private upstream details")
    response = @provider.usage
    assert_not response.success?
    assert_equal "Brandfetch usage is unavailable", response.error.message
    assert_nil response.error.details

    request.to_timeout
    assert_not @provider.usage.success?

    stub_viewer(type: "api-key", usage: { used: 2, quota: 800 })
    assert @provider.usage.success?, "failed requests must not poison the success cache"
  end

  private
    def stub_viewer(body)
      stub_request(:get, "https://api.brandfetch.io/v2/viewer")
        .to_return(status: 200, body: body.to_json)
    end
end
