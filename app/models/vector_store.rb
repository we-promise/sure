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

  def self.embedding_model
    ENV.fetch("EMBEDDING_MODEL", DEFAULT_EMBEDDING_MODEL)
  end

  def self.embedding_dimensions
    ENV.fetch("EMBEDDING_DIMENSIONS", DEFAULT_EMBEDDING_DIMENSIONS).to_i
  end

  def self.embedding_uri_base
    ENV["EMBEDDING_URI_BASE"].presence || ENV["OPENAI_URI_BASE"].presence || DEFAULT_EMBEDDING_URI_BASE
  end

  def self.embedding_access_token
    ENV["EMBEDDING_ACCESS_TOKEN"].presence || ENV["OPENAI_ACCESS_TOKEN"].presence
  end
end
