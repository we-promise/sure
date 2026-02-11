module VectorStore
  Error = Class.new(StandardError)
  ConfigurationError = Class.new(Error)

  Response = Data.define(:success?, :data, :error)

  def self.adapter
    Registry.adapter
  end

  def self.configured?
    Registry.configured?
  end
end
