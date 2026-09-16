require "test_helper"

class Provider::SimplefinClaimRetryTest < ActiveSupport::TestCase
  [ Net::ReadTimeout, Net::OpenTimeout, Errno::ECONNRESET, EOFError ].each do |error_class|
    test "a single-use claim does not replay #{error_class.name}" do
      claim_url = "https://example.com/private-claim-token"
      token = Base64.strict_encode64(claim_url)
      request = stub_request(:post, claim_url).to_raise(error_class.new("Private transport details #{claim_url}"))
      output = StringIO.new

      error = VCR.turned_off do
        Rails.stub(:logger, ActiveSupport::Logger.new(output)) do
          assert_raises(Provider::Simplefin::SimplefinError) { Provider::Simplefin.new.claim_access_url(token) }
        end
      end

      assert_requested request, times: 1
      assert_equal :network_error, error.error_type
      assert_equal "SimpleFIN network request failed", error.message
      assert_nil error.cause
      refute_includes output.string, "private-claim-token"
      refute_includes output.string, "Private transport details"
      refute_includes output.string, token
    end
  end

  test "a successful claim retains its access URL response" do
    claim_url = "https://example.com/claim"
    access_url = "https://access-user:access-secret@example.com/access"
    request = stub_request(:post, claim_url).to_return(status: 200, body: " #{access_url}\n")

    result = VCR.turned_off { Provider::Simplefin.new.claim_access_url(Base64.strict_encode64(claim_url)) }

    assert_equal access_url, result
    assert_requested request, times: 1
  end

  test "ordinary account reads still retry a transient failure" do
    access_url = "https://example.com/access"
    request = stub_request(:get, "#{access_url}/accounts")
      .to_raise(Net::ReadTimeout.new("Read failed"))
      .then.to_return(status: 200, body: '{"accounts": []}')
    provider = Provider::Simplefin.new
    provider.stubs(:sleep)

    result = VCR.turned_off { provider.get_accounts(access_url) }

    assert_equal({ accounts: [] }, result)
    assert_requested request, times: 2
  end

  test "a failed claim response does not expose server text or retry" do
    claim_url = "https://example.com/private-claim-token"
    request = stub_request(:post, claim_url).to_return(status: [ 500, "Private server details" ], body: "Private response body")

    error = VCR.turned_off do
      assert_raises(Provider::Simplefin::SimplefinError) do
        Provider::Simplefin.new.claim_access_url(Base64.strict_encode64(claim_url))
      end
    end

    assert_equal :claim_failed, error.error_type
    assert_equal "Failed to claim access URL (HTTP 500)", error.message
    assert_requested request, times: 1
  end
end
