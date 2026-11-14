# Adapter that delegates to OpenAI's hosted vector-store and file-search APIs, on the `embed`
# route's vector-store endpoint. OpenAI chunks, embeds and retrieves; Sure uploads files and
# searches.
#
# - A file is uploaded under the document's own name, which search results show the model.
# - Indexing is asynchronous: an upload answers `processing`, and VectorStore::IndexStatusJob
#   records the outcome.
# - Removing a file, or the store, deletes it from the Files API too, where it would otherwise
#   stay after the document or the family is gone.
class VectorStore::Openai < VectorStore::Base
  def initialize(endpoint:)
    @client = Ai::Transport::Http.openai_client(endpoint)
  end

  def create_store(name:)
    with_response do
      response = client.vector_stores.create(parameters: { name: name })
      { id: response["id"] }
    end
  end

  def delete_store(store_id:)
    with_response do
      file_ids(store_id).each { |file_id| delete_file(file_id) }
      client.vector_stores.delete(id: store_id)
    end
  end

  def upload_file(store_id:, file_content:, filename:, **)
    with_response do
      file_id = Dir.mktmpdir do |dir|
        path = File.join(dir, safe_filename(filename))
        File.binwrite(path, file_content)
        client.files.upload(parameters: { file: path, purpose: "assistants" })["id"]
      end

      begin
        client.vector_store_files.create(vector_store_id: store_id, parameters: { file_id: file_id })
      rescue => e
        delete_file(file_id)
        raise e
      end

      { file_id: file_id, status: "processing" }
    end
  end

  # Where OpenAI's indexing of a file stands: { status: ready | processing | unreadable | error,
  # error: }.
  def file_status(store_id:, file_id:)
    with_response do
      file = client.vector_store_files.retrieve(vector_store_id: store_id, id: file_id)
      case file["status"]
      when "in_progress" then { status: "processing" }
      when "completed" then { status: file["usage_bytes"].to_i.zero? ? "unreadable" : "ready" }
      else { status: "error", error: file.dig("last_error", "message") || file["status"] }
      end
    end
  end

  def remove_file(store_id:, file_id:)
    with_response do
      client.vector_store_files.delete(vector_store_id: store_id, id: file_id)
      delete_file(file_id)
    end
  end

  def search(store_id:, query:, max_results: 10, **)
    with_response do
      response = client.vector_stores.search(
        id: store_id,
        parameters: { query: query, max_num_results: max_results, ranking_options: { score_threshold: MIN_SCORE } }
      )

      (response["data"] || []).filter_map do |result|
        next if result["score"].to_f < MIN_SCORE

        {
          content: Array(result["content"]).filter_map { |c| c["text"] }.join("\n"),
          filename: result["filename"],
          score: result["score"],
          file_id: result["file_id"]
        }
      end
    end
  end

  private
    attr_reader :client

    def file_ids(store_id)
      ids = []
      after = nil
      loop do
        page = client.vector_store_files.list(vector_store_id: store_id, parameters: { limit: 100, after: }.compact)
        ids.concat(Array(page["data"]).map { _1["id"] })
        break unless page["has_more"] && ids.any?

        after = ids.last
      end
      ids
    end

    # A file already gone is fine; anything else is logged and left, so the rest still go.
    def delete_file(file_id)
      client.files.delete(id: file_id)
    rescue Faraday::ResourceNotFound
      nil
    rescue => e
      Rails.logger.warn("[VectorStore::Openai] couldn't delete file #{file_id}: #{e.class}")
    end

    def safe_filename(filename)
      name = File.basename(filename.to_s).gsub(/[^\w.\- ]/, "_").first(200)
      name.presence || "document"
    end
end
