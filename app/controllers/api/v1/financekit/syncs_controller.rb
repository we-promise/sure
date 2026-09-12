class Api::V1::Financekit::SyncsController < Api::V1::Financekit::BaseController
  def create
    raise Financekit::Error.new("payload_too_large", 413) if request.raw_post.bytesize > Financekit::MAX_BYTES

    batch = Financekit::Processor.new(connection).apply!(input)
    render_json({ id: batch.batch_id, status: batch.status, captured_at: batch.captured_at,
      applied_at: batch.applied_at, counts: batch.counts }, status: :created)
  end
end
