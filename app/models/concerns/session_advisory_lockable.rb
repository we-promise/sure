# A session-level advisory lock on one record: held by the database session
# rather than a transaction, so rows written under it commit one by one and a
# long block doesn't hold row locks it doesn't need. Re-entrant on the same
# connection.
#
# Never inside a caller's transaction: an error aborting it would make the
# unlock fail, leaving the lock with the pooled connection, where everything
# else waiting for it would wait for good.
module SessionAdvisoryLockable
  extend ActiveSupport::Concern

  # error: the exception raised when called inside an open transaction.
  def with_session_advisory_lock(namespace, error:)
    raise error, "#{self.class.name} #{id} must not take this lock inside a transaction" if self.class.current_transaction.open?

    connection = self.class.lease_connection
    key = [ namespace, id.to_s ]

    connection.execute(self.class.sanitize_sql_array([ "SELECT pg_advisory_lock(?, hashtext(?))", *key ]))
    sessions = (@advisory_lock_sessions ||= {})
    outermost = !sessions.key?(namespace)
    sessions[namespace] ||= backend_pid(connection)
    begin
      yield
    ensure
      release_session_advisory_lock(connection, key)
      sessions.delete(namespace) if outermost
    end
  end

  # The session that took the lock ended while the block ran: a broken
  # connection that Rails opened again on the next query, on a new session
  # that holds no lock, so someone else may hold it now. false outside it.
  def session_advisory_lock_lost?(namespace)
    session = @advisory_lock_sessions&.[](namespace)
    session.present? && backend_pid(self.class.lease_connection) != session
  end

  private
    # An unlock that does not run (the connection broke, the thread was
    # interrupted) would leave the lock with the connection; throwing the
    # connection away ends its session, which releases the lock. A session
    # that ended took the lock with it, and the new one has none to release.
    def release_session_advisory_lock(connection, key)
      released = false
      if session_advisory_lock_lost?(key.first)
        Rails.logger.warn "#{self.class.name} #{id} - The advisory lock ended with its database session while the block ran"
      else
        connection.execute(self.class.sanitize_sql_array([ "SELECT pg_advisory_unlock(?, hashtext(?))", *key ]))
      end
      released = true
    ensure
      connection.throw_away! unless released
    end

    def backend_pid(connection)
      connection.select_value("SELECT pg_backend_pid()")
    end
end
