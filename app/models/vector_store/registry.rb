class VectorStore::Registry
  ADAPTERS = {
    openai: "VectorStore::Openai",
    pgvector: "VectorStore::Pgvector",
    qdrant: "VectorStore::Qdrant"
  }.freeze

  class << self
    # Returns the configured adapter instance. Which store is used comes from
    # Ai::Config (Ai::LegacyEnvConfig keeps the rule: VECTOR_STORE_PROVIDER,
    # else pgvector on Anthropic installs, else OpenAI's store when the key is for OpenAI itself).
    def adapter
      name = adapter_name
      return nil unless name

      build_adapter(name)
    end

    def configured?
      adapter.present?
    end

    def adapter_name
      Ai::Config.current.vector_store_backend
    end

    # True when pgvector is the effective vector store — whether set explicitly
    # via VECTOR_STORE_PROVIDER or selected by the Anthropic default above.
    # Single source of truth shared with the migration that provisions
    # `vector_store_chunks`, so the table is created exactly when pgvector is in
    # use (an Anthropic-default install would otherwise skip it and fail on the
    # missing table).
    def pgvector_effective?
      adapter_name == :pgvector
    end

    private

      def build_adapter(name)
        klass = ADAPTERS[name]&.safe_constantize
        raise VectorStore::ConfigurationError, "Unknown vector store adapter: #{name}" unless klass

        case name
        when :openai   then build_openai
        when :pgvector then build_pgvector
        when :qdrant   then build_qdrant
        else raise VectorStore::ConfigurationError, "No builder defined for adapter: #{name}"
        end
      end

      # The `embed` route's vector store endpoint.
      def build_openai
        endpoint = Ai::Config.current.routes_for(:embed).map(&:endpoint).find(&:vector_store?)
        return nil unless endpoint&.api_key

        VectorStore::Openai.new(endpoint:)
      end

      def build_pgvector
        # Gate on availability (extension present, or table already created)
        # so an Anthropic-default install on a Postgres without pgvector
        # degrades to the assistant's "provider_not_configured" message
        # instead of raising raw PG errors mid-chat.
        return nil unless VectorStore::Pgvector.available?

        VectorStore::Pgvector.new
      end

      def build_qdrant
        url  = ENV.fetch("QDRANT_URL", "http://localhost:6333")
        api_key = ENV["QDRANT_API_KEY"].presence

        VectorStore::Qdrant.new(url: url, api_key: api_key)
      end
  end
end
