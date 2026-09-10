# Deliberately outside general API/session authentication. The only credential is
# a device-signed immutable JWS containing a destination-encrypted JWE. A leaked
# or redirected request cannot authorize any other endpoint or reveal its money.
class Api::V1::Financekit::BatchesController < ActionController::API
  rescue_from Financekit::Error, with: :protocol_error
  rescue_from ActiveRecord::RecordNotFound do
    render json: { error: "not_found" }, status: :not_found
  end

  def create
    raise Financekit::Error.new("invalid_content_type", 400) unless request.media_type == "application/jose"
    raise Financekit::Error.new("payload_too_large", 413) if request.content_length.to_i > Financekit::MAX_BYTES
    envelope = request.body.read(Financekit::MAX_BYTES + 1)
    item = FinancekitItem.find(params[:connection_id])
    batch = FinancekitBatch.accept!(item, envelope)
    render json: { receipt: Financekit::Crypto.receipt(batch) }, status: :accepted
  end

  private

    def protocol_error(error)
      response.headers["Retry-After"] = "60" if [ 429, 503 ].include?(error.status)
      render json: { error: error.code }, status: error.status
    end
end
