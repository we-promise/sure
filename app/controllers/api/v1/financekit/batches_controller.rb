class Api::V1::Financekit::BatchesController < ActionController::API
  rescue_from Financekit::Error, with: :protocol_error
  rescue_from ActiveRecord::RecordNotFound do
    render json: { error: "not_found" }, status: :not_found
  end

  def create
    raise Financekit::Error.new("invalid_content_type", 400) unless request.media_type == "application/json"
    raise Financekit::Error.new("payload_too_large", 413) if request.content_length.to_i > Financekit::MAX_BYTES

    item = FinancekitItem.find_by(publisher_id: params[:publisher_id])
    token = request.authorization&.match(/\ABearer ([A-Za-z0-9_-]+)\z/)&.captures&.first # pipelock:ignore Credential in URL
    raise Financekit::Error.new("publisher_unauthorized", 401) unless item&.authenticate_credential?(token)

    batch = FinancekitBatch.accept!(item, limited_body,
      claimed_digest: request.headers["X-Sure-Payload-SHA256"],
      idempotency_key: request.headers["Idempotency-Key"])
    render json: batch.receipt, status: :accepted
  end

  private

    def limited_body
      body = request.body
      result = +""
      while (chunk = body.read(16.kilobytes))
        result << chunk
        raise Financekit::Error.new("payload_too_large", 413) if result.bytesize > Financekit::MAX_BYTES
      end
      result
    end

    def protocol_error(error)
      response.headers["Retry-After"] = "60" if [ 429, 503 ].include?(error.status)
      render json: { error: error.code }, status: error.status
    end
end
