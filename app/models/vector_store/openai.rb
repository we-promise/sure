# Adapter that delegates to OpenAI's hosted vector-store and file-search APIs.
#
# Requirements:
#   - gem "ruby-openai" (already in Gemfile)
#   - OPENAI_ACCESS_TOKEN env var or Setting.openai_access_token
#
# OpenAI manages chunking, embedding, and retrieval; we simply upload files
# and issue search queries.
class VectorStore::Openai < VectorStore::Base
  def initialize(access_token:, uri_base: nil)
    client_options = { access_token: access_token }
    client_options[:uri_base] = uri_base if uri_base.present?
    client_options[:request_timeout] = ENV.fetch("OPENAI_REQUEST_TIMEOUT", 60).to_i

    @client = ::OpenAI::Client.new(**client_options)
  end

  def create_store(name:)
    with_response do
      response = client.vector_stores.create(parameters: { name: name })
      { id: response["id"] }
    end
  end

  def delete_store(store_id:)
    with_response do
      client.vector_stores.delete(id: store_id)
    end
  end

  def upload_file(store_id:, file_content:, filename:)
    with_response do
      tempfile = Tempfile.new([ File.basename(filename, ".*"), File.extname(filename) ])
      begin
        tempfile.binmode
        tempfile.write(file_content)
        tempfile.rewind

        file_response = client.files.upload(
          parameters: { file: tempfile, purpose: "assistants" }
        )
        file_id = file_response["id"]

        begin
          client.vector_store_files.create(
            vector_store_id: store_id,
            parameters: { file_id: file_id }
          )
        rescue => e
          client.files.delete(id: file_id) rescue nil
          raise
        end

        { file_id: file_id }
      ensure
        tempfile.close
        tempfile.unlink
      end
    end
  end

  def remove_file(store_id:, file_id:)
    with_response do
      client.vector_store_files.delete(vector_store_id: store_id, id: file_id)
    end
  end

  def search(store_id:, query:, max_results: 10)
    with_response do
      response = client.vector_stores.search(
        id: store_id,
        parameters: { query: query, max_num_results: max_results }
      )

      (response["data"] || []).map do |result|
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
end
