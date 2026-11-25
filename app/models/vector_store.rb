module VectorStore
  Error = Class.new(StandardError)
  ConfigurationError = Class.new(Error)

  # The upload succeeded but neither the attachment nor the compensating deletion did. The
  # uploaded file id has to reach the caller so a document row can keep it for a later retry.
  class UploadCleanupError < Error
    attr_reader :file_id, :attachment_error, :cleanup_error

    def initialize(file_id:, attachment_error:, cleanup_error:)
      @file_id = file_id
      @attachment_error = attachment_error
      @cleanup_error = cleanup_error
      super("uploaded file #{file_id} could not be attached or deleted (#{cleanup_error.class})")
    end
  end

  Response = Data.define(:success?, :data, :error)

  DEFAULT_EMBEDDING_MODEL = "mxbai-embed-large".freeze
  DEFAULT_EMBEDDING_DIMENSIONS = 1024
  # What a document records as the store that accepted it: "openai", "pgvector" or "qdrant".
  def self.backend_name(adapter) = adapter.class.name.demodulize.underscore

  DEFAULT_EMBEDDING_URI_BASE = "https://api.openai.com/v1/".freeze

  def self.adapter
    Registry.adapter
  end

  # The store that accepted a family's documents, which can differ from the one configured now.
  # A document predating the recorded backend uses the configured adapter.
  def self.adapter_for(backend, endpoint_url: nil)
    return adapter if backend.blank?
    return Openai.for_store(endpoint_url) if backend == "openai"
    return Pgvector.new if backend == "pgvector" && Pgvector.available?

    configured = adapter
    configured if configured && backend_name(configured) == backend
  end

  def self.configured?
    Registry.configured?
  end

  # The embedding model and server come from the `embed` route (Ai::Config), which reads
  # EMBEDDING_* and falls back to the OpenAI URL and key, from ENV or Settings.
  def self.embedding_model
    embedding_config&.name || DEFAULT_EMBEDDING_MODEL
  end

  def self.embedding_dimensions
    embedding_config&.embedding_dimensions || DEFAULT_EMBEDDING_DIMENSIONS
  end

  def self.embedding_uri_base
    embedding_config&.endpoint&.base_url || DEFAULT_EMBEDDING_URI_BASE
  end

  def self.embedding_access_token
    embedding_config&.endpoint&.api_key
  end

  def self.embedding_config = Ai::Config.current.embedding_model
end
