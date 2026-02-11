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

    unless family.vector_store_id.present?
      return {
        success: false,
        error: "no_documents",
        message: "No documents have been uploaded to the family document store yet."
      }
    end

    adapter = VectorStore.adapter

    unless adapter
      return {
        success: false,
        error: "provider_not_configured",
        message: "No vector store is configured. Set VECTOR_STORE_PROVIDER or configure OpenAI."
      }
    end

    response = adapter.search(
      store_id: family.vector_store_id,
      query: query,
      max_results: max_results
    )

    unless response.success?
      return {
        success: false,
        error: "search_failed",
        message: "Failed to search documents: #{response.error&.message}"
      }
    end

    results = response.data

    if results.empty?
      return {
        success: true,
        results: [],
        message: "No matching documents found for the query."
      }
    end

    {
      success: true,
      query: query,
      result_count: results.size,
      results: results.map do |result|
        {
          content: result[:content],
          filename: result[:filename],
          score: result[:score]
        }
      end
    }
  rescue => e
    Rails.logger.error("SearchFamilyFiles error: #{e.class.name} - #{e.message}")
    {
      success: false,
      error: "search_failed",
      message: "An error occurred while searching documents: #{e.message.truncate(200)}"
    }
  end
end
