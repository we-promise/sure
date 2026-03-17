require "test_helper"
require "ostruct"

class Eval::LangfuseClientTest < ActiveSupport::TestCase
  # -- CRL error list --

  test "crl_errors includes standard CRL error codes" do
    errors = Eval::Langfuse::Client.crl_errors

    assert_includes errors, OpenSSL::X509::V_ERR_UNABLE_TO_GET_CRL
    assert_includes errors, OpenSSL::X509::V_ERR_CRL_HAS_EXPIRED
    assert_includes errors, OpenSSL::X509::V_ERR_CRL_NOT_YET_VALID
  end

  test "crl_errors is frozen" do
    assert Eval::Langfuse::Client.crl_errors.frozen?
  end

  # -- CRL verify callback behavior --
  # The callback should bypass only CRL-specific errors while preserving the
  # original verification result for all other error types.

  test "CRL callback returns true for CRL-unavailable errors" do
    crl_error_codes = Eval::Langfuse::Client.crl_errors
    store_ctx = OpenStruct.new(error: OpenSSL::X509::V_ERR_UNABLE_TO_GET_CRL)

    callback = build_crl_callback(crl_error_codes)

    assert callback.call(false, store_ctx), "CRL errors should be bypassed even when preverify_ok is false"
  end

  test "CRL callback preserves preverify_ok for non-CRL errors" do
    crl_error_codes = Eval::Langfuse::Client.crl_errors
    # V_OK (0) is not a CRL error
    store_ctx = OpenStruct.new(error: 0)

    callback = build_crl_callback(crl_error_codes)

    assert callback.call(true, store_ctx), "Non-CRL errors with preverify_ok=true should pass"
    refute callback.call(false, store_ctx), "Non-CRL errors with preverify_ok=false should fail"
  end

  test "CRL callback rejects cert errors that are not CRL-related" do
    crl_error_codes = Eval::Langfuse::Client.crl_errors
    # V_ERR_CERT_HAS_EXPIRED is a real cert error, not CRL
    store_ctx = OpenStruct.new(error: OpenSSL::X509::V_ERR_CERT_HAS_EXPIRED)

    callback = build_crl_callback(crl_error_codes)

    refute callback.call(false, store_ctx), "Non-CRL cert errors should not be bypassed"
  end

  private

    # Reconstructs the same lambda used in Eval::Langfuse::Client#execute_request
    # for isolated testing without needing a real Net::HTTP connection.
    def build_crl_callback(crl_error_codes)
      ->(preverify_ok, store_ctx) {
        if crl_error_codes.include?(store_ctx.error)
          true
        else
          preverify_ok
        end
      }
    end
end
