class Assistant::Function::SearchFamilyFiles < Assistant::Function
  class << self
    def name
      "search_family_files"
    end

    def description
      <<~DESC
        Search through documents that the family has uploaded to their financial document store.

        Use this when the user asks questions about their uploaded financial documents such as
        tax returns, bank statements, contracts, insurance policies, investment reports, or any
        other files they've imported.

        Returns relevant excerpts from matching documents along with the source filename and
        a relevance score.

        Supported file types include: PDF, DOCX, XLSX, PPTX, TXT, CSV, JSON, XML, HTML, MD,
        and common source code formats.

        Example:

        ```
        search_family_files({
          query: "What was the total income on my 2024 tax return?"
        })
        ```
      DESC
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "query" ],
      properties: {
        query: {
          type: "string",
          description: "The search query to find relevant information in the family's uploaded documents"
        },
        max_results: {
          type: "integer",
          description: "Maximum number of results to return (default: 10, max: 20)"
        }
      }
    )
  end

  def call(params = {})
    query = params["query"]
    max_results = (params["max_results"] || 10).to_i.clamp(1, 20)

    Rails.logger.debug("[SearchFamilyFiles] query=#{query.inspect} max_results=#{max_results} family_id=#{family.id}")

    unless family.vector_store_id.present?
      Rails.logger.debug("[SearchFamilyFiles] family #{family.id} has no vector_store_id")
      return {
        success: false,
        error: "no_documents",
        message: "No documents have been uploaded to the family document store yet."
      }
    end

    adapter = VectorStore.adapter

    unless adapter
      Rails.logger.debug("[SearchFamilyFiles] no VectorStore adapter configured")
      return {
        success: false,
        error: "provider_not_configured",
        message: "No vector store is configured. Set VECTOR_STORE_PROVIDER or configure OpenAI."
      }
    end

    store_id = family.vector_store_id
    Rails.logger.debug("[SearchFamilyFiles] searching store_id=#{store_id} via #{adapter.class.name}")

    trace = create_langfuse_trace(
      name: "search_family_files",
      input: { query: query, max_results: max_results, store_id: store_id }
    )

    response = adapter.search(
      store_id: store_id,
      query: query,
      max_results: max_results
    )

    unless response.success?
      error_msg = response.error&.message
      Rails.logger.debug("[SearchFamilyFiles] search failed: #{error_msg}")
      begin
        langfuse_client&.trace(id: trace.id, output: { error: error_msg }, level: "ERROR") if trace
      rescue => e
        Rails.logger.debug("[SearchFamilyFiles] Langfuse trace update failed: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
      end
      return {
        success: false,
        error: "search_failed",
        message: "Failed to search documents: #{error_msg}"
      }
    end

    results = response.data

    Rails.logger.debug("[SearchFamilyFiles] #{results.size} chunk(s) returned")

    results.each_with_index do |r, i|
      Rails.logger.debug(
        "[SearchFamilyFiles] chunk[#{i}] score=#{r[:score]} file=#{r[:filename].inspect} " \
        "content_length=#{r[:content]&.length} preview=#{r[:content]&.truncate(10).inspect}"
      )
    end

    mapped = results.map do |result|
      { content: result[:content], filename: result[:filename], score: result[:score] }
    end

    output = if mapped.empty?
      { success: true, results: [], message: "No matching documents found for the query." }
    else
      { success: true, query: query, result_count: mapped.size, results: mapped }
    end

    begin
      if trace
        langfuse_client&.trace(id: trace.id, output: {
          result_count: mapped.size,
          chunks: mapped.map { |r| { filename: r[:filename], score: r[:score], content_length: r[:content]&.length } }
        })
      end
    rescue => e
      Rails.logger.debug("[SearchFamilyFiles] Langfuse trace update failed: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    end

    output
  rescue => e
    Rails.logger.error("[SearchFamilyFiles] error: #{e.class.name} - #{e.message}")
    {
      success: false,
      error: "search_failed",
      message: "An error occurred while searching documents: #{e.message.truncate(200)}"
    }
  end

  private
    def langfuse_client
      return unless ENV["LANGFUSE_PUBLIC_KEY"].present? && ENV["LANGFUSE_SECRET_KEY"].present?

      @langfuse_client ||= Langfuse.new
    end

    def create_langfuse_trace(name:, input:)
      return unless langfuse_client

      langfuse_client.trace(
        name: name,
        input: input,
        user_id: user.id&.to_s,
        environment: Rails.env
      )
    rescue => e
      Rails.logger.debug("[SearchFamilyFiles] Langfuse trace creation failed: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
      nil
    end
end
