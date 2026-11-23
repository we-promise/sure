# Always listed: it searches documents' contents when `search_documents` is
# available, and otherwise falls back to #3422's metadata search over the vault, saying why with
# the router's reason, never "no documents have been uploaded". On pgvector and Qdrant the query's
# embedding is an `embed.ai` call, traced and recorded like any other; OpenAI's store embeds the
# query itself, inside its search API, so that path has no `embed.ai` event.
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

    availability = Ai.availability(:search_documents, family:, user:)
    unless availability.available?
      Rails.logger.debug("[SearchFamilyFiles] search_documents unavailable: #{availability.reason}")
      return statement_fallback(query, max_results, reason: availability.reason.to_s, availability:)
    end

    unless family.vector_store_id.present?
      Rails.logger.debug("[SearchFamilyFiles] family #{family.id} has no vector_store_id")
      return statement_fallback(query, max_results, reason: "no_vector_store")
    end

    adapter = VectorStore.adapter
    return statement_fallback(query, max_results, reason: "not_configured") unless adapter

    # The same candidate retrieval as Family#search_documents: a restricted hit must not spend the
    # caller's limit. Keep this tool's explicit provider-error response rather than the family's [].
    results, response = family.search_document_hits(query, max_results: max_results, user: user)
    # nil: the server that holds the family's store is no longer configured.
    return statement_fallback(query, max_results, reason: "not_configured") if response.nil?

    unless response.success?
      error_msg = response.error&.message
      Rails.logger.debug("[SearchFamilyFiles] search failed: #{error_msg}")
      return {
        success: false,
        error: "search_failed",
        message: "Failed to search documents: #{error_msg}"
      }
    end

    Rails.logger.debug("[SearchFamilyFiles] #{results.size} readable chunk(s) returned")

    results.each_with_index do |r, i|
      Rails.logger.debug(
        "[SearchFamilyFiles] chunk[#{i}] score=#{r[:score]} file=#{r[:filename].inspect} " \
        "content_length=#{r[:content]&.length} preview=#{r[:content]&.truncate(10).inspect}"
      )
    end

    mapped = results.map do |result|
      { content: result[:content], filename: result[:filename], score: result[:score] }
    end

    if mapped.empty?
      { success: true, results: [], message: "No matching documents found for the query." }
    else
      { success: true, query: query, result_count: mapped.size, results: mapped }
    end
  rescue => e
    Rails.logger.error("[SearchFamilyFiles] error: #{e.class.name} - #{e.message}")
    {
      success: false,
      error: "search_failed",
      message: "An error occurred while searching documents: #{e.message.truncate(200)}"
    }
  end

  private
    # Search over the vault's metadata (filename, institution and account hints), not contents;
    # get_document_text reads one statement's text. The role check every vault tool makes comes
    # first: guests reach this tool, and the vault's inventory isn't theirs to list.
    def statement_fallback(query, max_results, reason:, availability: nil)
      return not_a_manager_result(query, reason) unless AccountStatement.statement_manager?(user)

      statements, matched = matching_statements(query, max_results)

      {
        success: true,
        search_mode: "metadata_only",
        reason: reason,
        query: query,
        # Whether these rows match the query or are only the latest on file, so an assistant
        # doesn't present the latter as answers.
        listing: matched ? "matched" : "most_recent",
        result_count: statements.size,
        results: statements.map { |statement| statement_result(statement) },
        message: fallback_message(reason, statements.size, matched, availability:)
      }
    end

    # "You may not list this", not "there is nothing here".
    def not_a_manager_result(query, reason)
      {
        success: true,
        search_mode: "metadata_only",
        reason: reason,
        query: query,
        result_count: 0,
        results: [],
        message: "Full-text document search is not configured on this install, and listing the " \
                 "statement vault requires an admin or member role. Say that the documents could " \
                 "not be listed for this user, NOT that no document exists."
      }
    end

    def matching_statements(query, max_results)
      scope = family.account_statements
                    .where(account_id: [ nil, *user.accessible_accounts.pluck(:id) ])
                    .order(Arel.sql("period_end_on DESC NULLS LAST"), created_at: :desc)

      terms = query.to_s.split(/\s+/).select { |term| term.length >= 3 }

      unless terms.empty?
        matched = terms.reduce(scope) do |relation, term|
          relation.where(
            "filename ILIKE :term OR institution_name_hint ILIKE :term OR account_name_hint ILIKE :term",
            term: "%#{ActiveRecord::Base.sanitize_sql_like(term)}%"
          )
        end.limit(max_results).to_a

        # No match falls back to the latest statements, so an over-specific query doesn't read as
        # an empty vault.
        return [ matched, true ] if matched.any?
      end

      [ scope.limit(max_results).to_a, false ]
    end

    def statement_result(statement)
      {
        account_statement_id: statement.id,
        filename: statement.filename,
        period_start_on: statement.period_start_on,
        period_end_on: statement.period_end_on,
        institution: statement.institution_name_hint,
        account_id: statement.account_id
      }.compact
    end

    def fallback_message(reason, count, matched = true, availability: nil)
      base = case reason
      when "no_vector_store"
        "No document has been indexed for full-text search yet, so only stored statements are listed."
      when "not_configured"
        if availability
          "Searching documents by their contents isn't set up: #{availability.message_for(user)}"
        else
          "No vector store is configured, so documents cannot be searched by their contents. " \
          "Set VECTOR_STORE_PROVIDER (openai | pgvector | qdrant), or for an Anthropic-only install " \
          "enable the pgvector adapter and point EMBEDDING_URI_BASE at an embeddings endpoint."
        end
      else
        "Searching documents by their contents isn't available for this user (#{reason}): " \
        "#{availability&.message_for(user) || reason}."
      end

      return "#{base} No stored statement is available to this user either." if count.zero?

      listing = if matched
        "#{count} stored statement(s) match the query by filename or institution"
      else
        "Nothing matched the query, so the #{count} MOST RECENT statement(s) are listed instead. " \
        "Do not present them as answers to the question: say the vault holds these and ask the " \
        "user which one to read"
      end

      "#{base} #{listing}, by metadata only. " \
      "Call get_document_text with an account_statement_id to read one of them."
    end
end
