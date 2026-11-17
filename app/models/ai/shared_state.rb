# Short-lived values a job hands to the web: probe results, the worker snapshot and, later, tool
# results and the gate's state. Stored as JSON in Sidekiq's Redis, which every web and worker
# process shares on every install. Rails.cache isn't shared on all of them: it's a null or
# per-process store in development and test, and a per-process file store in production without
# REDIS_URL (a Sentinel install, for one).
module Ai::SharedState
  # The store's interface is ActiveSupport::Cache's `write`, `read` and `delete`, so a test can
  # use a MemoryStore instead of the Redis that parallel test processes share.
  class RedisStore
    def write(key, value, expires_in:)
      Sidekiq.redis { _1.call("SET", key, value, "EX", expires_in.to_i) }
    end

    def read(key) = Sidekiq.redis { _1.call("GET", key) }

    def delete(key) = Sidekiq.redis { _1.call("DEL", key) }
  end

  class << self
    attr_writer :store

    def store = @store ||= RedisStore.new

    def write(key, value, expires_in:)
      store.write(key, value.to_json, expires_in:)
    end

    def read(key)
      json = store.read(key)
      JSON.parse(json) if json
    end

    def delete(key) = store.delete(key)
  end
end
