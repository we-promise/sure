class Api::V1::Financekit::SyncsController < Api::V1::Financekit::BaseController
  def create
    declared = request.content_length unless request.get_header("HTTP_TRANSFER_ENCODING").present?
    raise Financekit::Error.new("payload_too_large", 413) if declared && declared > Financekit::MAX_BYTES
    raise Financekit::Error.new("payload_too_large", 413) if request.raw_post.bytesize > Financekit::MAX_BYTES

    batch = Financekit::Processor.new(connection).apply!(input)
    render_json({ id: batch.batch_id, status: batch.status, captured_at: batch.captured_at,
      applied_at: batch.applied_at, counts: batch.counts }, status: :created)
  end
end
