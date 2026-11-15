module VectorStore
  Error = Class.new(StandardError)
  ConfigurationError = Class.new(Error)

  Response = Data.define(:success?, :data, :error)

  DEFAULT_EMBEDDING_MODEL = "mxbai-embed-large".freeze
  DEFAULT_EMBEDDING_DIMENSIONS = 1024
  DEFAULT_EMBEDDING_URI_BASE = "https://api.openai.com/v1/".freeze

  def self.adapter
    Registry.adapter
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
