module FamilyLockTestHelper
  # Holds the recurring pipeline's advisory lock for a family from a separate
  # PG session. Transactional tests share one session, and a session can
  # always re-take its own advisory lock, so this needs a genuinely separate one.
  def with_family_lock_held_elsewhere(family_id)
    key = RecurringTransaction::Pipeline.advisory_lock_key(family_id)
    config = ActiveRecord::Base.connection_pool.db_config.configuration_hash
    other = PG.connect({
      dbname: config[:database], host: config[:host], port: config[:port],
      user: config[:username], password: config[:password]
    }.compact)
    other.exec("SELECT pg_advisory_lock(#{key})")
    yield
  ensure
    other&.close
  end
end
