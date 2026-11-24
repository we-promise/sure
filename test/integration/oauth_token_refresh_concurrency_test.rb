require "test_helper"
require "timeout"

# A password change has to end every refresh chain that was alive when it
# started, including one whose refresh is already in progress. The refresh
# and the password change each run on their own thread and connection with
# real commits, because what matters is which rows one transaction can see
# of the other.
class OauthTokenRefreshConcurrencyTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  NEW_PASSWORD = "NewSecure1!pass".freeze

  setup do
    @user = users(:family_member)
    @original_password_digest = @user.password_digest
    @oauth_app = Doorkeeper::Application.create!(
      name: "Refresh race #{SecureRandom.hex(4)}",
      redirect_uri: "https://client.example.com/callback",
      scopes: "read_write"
    )
    @token = Doorkeeper::AccessToken.create!( # pipelock:ignore
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write",
      expires_in: 2.hours,
      use_refresh_token: true
    )
    @threads = []
    @releases = []
  end

  teardown do
    @releases.each { |release| release << true }
    @threads.each do |thread|
      blocking { thread.join(10) }
      thread.kill if thread.alive?
    end
    release_minting
    Doorkeeper::AccessToken.where(application_id: @oauth_app.id).delete_all
    Doorkeeper::AccessGrant.where(application_id: @oauth_app.id).delete_all
    @oauth_app.delete
    User.where(id: @user.id).update_all(password_digest: @original_password_digest)
  end

  test "a refresh that validated its token before a password change leaves no usable successor" do
    minting = Queue.new
    mint = release_queue
    hold_minting(minting, mint)

    refresh = in_thread { refresh_with(@token.plaintext_refresh_token) }
    blocking { Timeout.timeout(10) { minting.pop } }

    change = in_thread { change_password }
    wait_until_finished_or_lock_waiting(change)

    mint << true
    status, body = blocking { refresh.value }
    release_minting
    assert blocking { change.join(10) }, "the password change must finish once the refresh commits"

    assert_equal 200, status, "the refresh started first, so it is allowed to complete"
    successor = Doorkeeper::AccessToken.where(application_id: @oauth_app.id).where.not(id: @token.id).sole
    assert successor.revoked?, "the successor minted during the password change must be revoked by it"
    assert @token.reload.revoked?

    status, body = refresh_with(body["refresh_token"])
    assert_equal 400, status
    assert_equal "invalid_grant", body["error"]
  end

  test "a refresh that arrives during a password change waits for it and is refused" do
    changed = Queue.new
    commit = release_queue
    change = in_thread do
      User.transaction do
        change_password
        changed << true
        commit.pop
      end
    end
    blocking { Timeout.timeout(10) { changed.pop } }

    refresh = in_thread { refresh_with(@token.plaintext_refresh_token) }
    wait_until_finished_or_lock_waiting(refresh)

    commit << true
    assert blocking { change.join(10) }, "the password change must commit"
    status, body = blocking { refresh.value }

    assert_equal 400, status
    assert_equal "invalid_grant", body["error"]
    assert_not Doorkeeper::AccessToken.where(application_id: @oauth_app.id).where.not(id: @token.id).exists?,
      "a refused refresh must not leave a token behind"
  end

  private

    def change_password
      User.find(@user.id).update!(password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD)
    end

    def refresh_with(refresh_token)
      session = open_session
      session.post "/oauth/token", params: {
        grant_type: "refresh_token",
        refresh_token: refresh_token,
        client_id: @oauth_app.uid,
        client_secret: @oauth_app.plaintext_secret
      }
      [ session.response.status, JSON.parse(session.response.body) ]
    end

    def in_thread
      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { yield }
      end
      thread.report_on_exception = false
      @threads << thread
      thread
    end

    def release_queue
      Queue.new.tap { |queue| @releases << queue }
    end

    # Parks the refresh after Doorkeeper has validated the presented token and
    # before it inserts the successor: the window the password change has to
    # close.
    def hold_minting(minting, mint)
      original = Doorkeeper::AccessToken.method(:create_for)
      Doorkeeper::AccessToken.define_singleton_method(:create_for) do |**attributes|
        minting << true
        mint.pop
        original.call(**attributes)
      end
    end

    def release_minting
      return unless Doorkeeper::AccessToken.singleton_class.method_defined?(:create_for, false)

      Doorkeeper::AccessToken.singleton_class.remove_method(:create_for)
    end

    # The second request either completes on its own or ends up queued behind
    # the first one's row lock; anything else within the deadline means the
    # schedule never formed. Each parallel worker has its own database, so a
    # blocked backend on this one belongs to this test.
    def wait_until_finished_or_lock_waiting(thread)
      deadline = 10.seconds.from_now
      loop do
        return unless thread.alive?
        return if lock_waiting?

        flunk "the concurrent request neither finished nor waited on a lock" if Time.current > deadline
        blocking { sleep 0.01 }
      end
    end

    def lock_waiting?
      ActiveRecord::Base.uncached do
        ActiveRecord::Base.connection.select_value(<<~SQL)
          SELECT EXISTS (
            SELECT 1 FROM pg_stat_activity
            WHERE datname = current_database() AND cardinality(pg_blocking_pids(pid)) > 0
          )
        SQL
      end
    end

    # The test thread holds the autoload interlock; let a request thread load
    # constants while this one is only waiting on it.
    def blocking(&)
      ActiveSupport::Dependencies.interlock.permit_concurrent_loads(&)
    end
end
