class SureImport < Import
  MAX_NDJSON_SIZE = 10.megabytes
  ALLOWED_NDJSON_CONTENT_TYPES = %w[
    application/x-ndjson
    application/ndjson
    application/json
    application/octet-stream
    text/plain
  ].freeze

  has_one_attached :ndjson_file, dependent: :purge_later

  def requires_csv_workflow?
    false
  end

  def column_keys
    []
  end

  def uploaded?
    ndjson_file.attached?
  end

  def configured?
    uploaded?
  end

  def publishable?
    uploaded?
  end
end
