# Short-lived values a job hands to the web: probe results, the worker snapshot and, later, tool
# results and the gate's state. Stored as JSON in Sidekiq's Redis, which every web and worker
# process shares on every install. Rails.cache isn't shared on all of them: it's a null or
# per-process store in development and test, and a per-process file store in production without
# REDIS_URL (a Sentinel install, for one).
module Ai::SharedState
  # The store's interface is ActiveSupport::Cache's `write`, `read` and `delete`, so a test can
  # use a MemoryStore instead of the Redis that parallel test processes share.
  class RedisStore
    # `unless_exist` maps to Redis's atomic SET NX PX, the same claim pattern
    # MarketDataResetJob uses for its enqueue guard.
    def write(key, value, expires_in:, unless_exist: false)
      args = [ "SET", key, value ]
      args.push("NX") if unless_exist
      args.push("PX", (expires_in.to_f * 1000).ceil)
      Sidekiq.redis { _1.call(*args) }
    end

    def read(key) = Sidekiq.redis { _1.call("GET", key) }

    def delete(key) = Sidekiq.redis { _1.call("DEL", key) }
  end

  class << self
    attr_writer :store

    def store = @store ||= RedisStore.new

    # Every value expires: nothing here outlives the work that wrote it.
    def write(key, value, expires_in:)
      raise ArgumentError, "expires_in must be positive, got #{expires_in.inspect}" unless expires_in.to_f.positive?

      store.write(key, value.to_json, expires_in:)
    end

    # Atomically take a key or return the value another caller put there first.
    # A losing caller can join the work that owns the key; a winner owns it
    # until the TTL or an explicit delete.
    def claim(key, value, expires_in:)
      raise ArgumentError, "expires_in must be positive, got #{expires_in.inspect}" unless expires_in.to_f.positive?

      won = store.write(key, value.to_json, expires_in:, unless_exist: true)
      won ? nil : read(key)
    end

    def read(key)
      json = store.read(key)
      JSON.parse(json) if json
    end

    def delete(key) = store.delete(key)
  end
end
