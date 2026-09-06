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

    # "No documents have been uploaded" was answered whenever no vector store
    # had ever been created, which is a different statement entirely and was
    # read as fact by assistants while the user's file sat in the database. Both
    # unconfigured cases now fall back to what CAN be searched without
    # embeddings, so the answer is "here is what exists, full-text search is
    # unavailable" rather than "you uploaded nothing".
    unless family.vector_store_id.present?
      Rails.logger.debug("[SearchFamilyFiles] family #{family.id} has no vector_store_id")
      return statement_fallback(query, max_results, reason: "no_vector_store")
    end

    adapter = VectorStore.adapter

    unless adapter
      Rails.logger.debug("[SearchFamilyFiles] no VectorStore adapter configured")
      return statement_fallback(query, max_results, reason: "provider_not_configured")
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

    mapped = family.readable_documents(results, user).map do |result|
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
    # Metadata-only search over the Statement Vault: filename, institution and
    # account hints. No document CONTENT, because extracting it is exactly what
    # needs the machinery that is missing here. get_document_text reads one
    # statement's text directly and is the right next call.
    def statement_fallback(query, max_results, reason:)
      # The same gate every other vault tool opens with (GetDocumentText,
      # ListAccountStatements, GetAccountStatement, UploadAccountStatement).
      # Full-text search being unconfigured must not become a way around the
      # role check: this tool is not preview-gated and no controller filters on
      # role, so a guest reaches it, and the vault inventory, filenames and
      # institution hints included, is not theirs to list. Unlinked statements
      # in particular require statement_manager? per AccountStatement#viewable_by?.
      return not_a_manager_result(query, reason) unless AccountStatement.statement_manager?(user)

      statements = matching_statements(query, max_results)

      {
        success: true,
        search_mode: "metadata_only",
        reason: reason,
        query: query,
        result_count: statements.size,
        results: statements.map { |statement| statement_result(statement) },
        message: fallback_message(reason, statements.size)
      }
    end

    # Distinguished from an empty vault on purpose: "you may not list this" and
    # "there is nothing here" are different answers, and collapsing them is the
    # mistake this whole fallback exists to undo.
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
                    .order(period_end_on: :desc, created_at: :desc)

      terms = query.to_s.split(/\s+/).select { |term| term.length >= 3 }

      unless terms.empty?
        matched = terms.reduce(scope) do |relation, term|
          relation.where(
            "filename ILIKE :term OR institution_name_hint ILIKE :term OR account_name_hint ILIKE :term",
            term: "%#{ActiveRecord::Base.sanitize_sql_like(term)}%"
          )
        end
        # An over-specific query must not read as "nothing was ever uploaded",
        # so an empty match falls back to the most recent statements.
        scope = matched if matched.exists?
      end

      scope.limit(max_results).to_a
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

    def fallback_message(reason, count)
      base = if reason == "provider_not_configured"
        "No vector store is configured, so documents cannot be searched by their contents. " \
        "Set VECTOR_STORE_PROVIDER (openai | pgvector | qdrant), or for an Anthropic-only install " \
        "enable the pgvector adapter and point EMBEDDING_URI_BASE at an embeddings endpoint."
      else
        "No document has been indexed for full-text search yet, so only stored statements are listed."
      end

      if count.zero?
        "#{base} No statement is stored either, so there is genuinely nothing on file."
      else
        "#{base} #{count} stored statement(s) are listed by metadata only. " \
        "Call get_document_text with an account_statement_id to read one of them."
      end
    end

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
