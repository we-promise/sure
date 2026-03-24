# frozen_string_literal: true

# Patch ActiveSupport::Cache::RedisCacheStore to work with connection_pool >= 3.0.
#
# connection_pool 3.0 switched from positional to keyword-only arguments in
# ConnectionPool.new.  Rails 7.2's RedisCacheStore still passes a positional
# hash, causing:
#
#   ArgumentError: wrong number of arguments (given 1, expected 0)
#
# The one-character fix: **pool_options instead of pool_options.
# Safe to remove once Rails ships a version with the upstream fix.

if defined?(ConnectionPool) && ConnectionPool::VERSION >= "3"
  class ActiveSupport::Cache::RedisCacheStore < ActiveSupport::Cache::Store
    def initialize(error_handler: DEFAULT_ERROR_HANDLER, **redis_options)
      universal_options = redis_options.extract!(*UNIVERSAL_OPTIONS)

      if pool_options = self.class.send(:retrieve_pool_options, redis_options)
        @redis = ::ConnectionPool.new(**pool_options) { self.class.build_redis(**redis_options) }
      else
        @redis = self.class.build_redis(**redis_options)
      end

      @max_key_bytesize = MAX_KEY_BYTESIZE
      @error_handler = error_handler

      super(universal_options)
    end
  end
end
