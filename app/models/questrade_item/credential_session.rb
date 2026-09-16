# One admitted legacy operation owns its rotating token until local consumers
# finish. The session lock spans HTTP; row transactions never do.
class QuestradeItem::CredentialSession
  Fence = Provider::AccountData::LegacyWriterFence
  DENIAL_ERRORS = [ Fence::OwnershipChanged, Fence::Busy, Fence::InvalidSource ].freeze
  CONTEXT_KEY = :questrade_legacy_credential_session
  CREDENTIAL_FIELDS = %w[family_id refresh_token api_server status].freeze
  METHODS = %i[list_accounts get_holdings get_balances get_symbols get_activities].freeze

  def self.with(item, sync: nil, allow_unusable: false, allow_completed: false)
    outer_session = nil
    result = Fence.with_item(item, operation: :credentials) do |current|
      held = ActiveSupport::IsolatedExecutionState[CONTEXT_KEY]
      if held
        held.assert_owner!(current)
        current_sync = Fence.scoped_sync!(current, sync, allow_completed: allow_completed)
        held.bind_sync!(current_sync, allow_completed: allow_completed)
        held.assert_current!
        return yield held, current_sync
      end
      ApplicationRecord.connection_pool.with_connection do |database|
        raise Fence::InvalidSource, "Questrade credential operations require no enclosing transaction" unless database.open_transactions.zero?
        key = "hashtextextended(#{database.quote("questrade_legacy_credentials:#{current.id}")}, 0)"
        session = nil
        failure = nil
        acquiring = false
        acquired = false
        begin
          acquiring = true
          acquired = database.select_value("SELECT pg_try_advisory_lock(#{key})")
          acquiring = false
          raise Fence::Busy, "Questrade credentials are in use" unless acquired
          session = new(current, database: database, allow_unusable: allow_unusable)
          outer_session = session
          current_sync = Fence.scoped_sync!(current, sync, allow_completed: allow_completed)
          session.bind_sync!(current_sync, allow_completed: allow_completed)
          ActiveSupport::IsolatedExecutionState[CONTEXT_KEY] = session
          yield session, current_sync
        rescue Exception => error # rubocop:disable Lint/RescueException -- release on interruption as well
          failure = error
          raise
        ensure
          session&.close!
          ActiveSupport::IsolatedExecutionState.delete(CONTEXT_KEY)
          begin
            raise Fence::OwnershipChanged, "Questrade credential lock acquisition is uncertain" if acquiring
            if acquired
              released = database.select_value("SELECT pg_advisory_unlock(#{key})")
              raise Fence::OwnershipChanged, "Questrade credential session lost its lock" unless released
            end
          rescue StandardError => release_error
            begin
              database.disconnect!
            rescue StandardError
              # Preserve the operation's original exception if cleanup fails.
            end
            raise release_error unless failure
          end
        end
      end
    end
    outer_session&.dispatch!
    result
  rescue ActiveRecord::RecordNotFound
    raise Fence::OwnershipChanged, "Questrade source is missing or changed", cause: nil
  end

  # Existing factory callers receive no credentials or reusable unguarded SDK.
  class Client
    def initialize(item)
      @item_id, @family_id = item.id.to_s.dup.freeze, item.family_id.to_s.dup.freeze
    end

    METHODS.each do |method|
      define_method(method) do |**arguments|
        item = QuestradeItem.find_by(id: @item_id, family_id: @family_id)
        raise Fence::OwnershipChanged, "Questrade client lost its original owner" unless item
        QuestradeItem::CredentialSession.with(item) { |session| session.provider.public_send(method, **arguments) }
      end
    end

    def inspect
      "#<#{self.class.name}>"
    end
  end

  attr_reader :item

  def initialize(item, database:, allow_unusable:)
    @item, @database = item, database
    @item_id = item.id.to_s.dup.freeze
    @item.reload
    @expected = @item.attributes.slice(*CREDENTIAL_FIELDS)
    assert_current!
    assert_usable! unless allow_unusable
  end

  def assert_owner!(current)
    unless !@closed && @database.equal?(ApplicationRecord.connection) && current.id == @item_id && current.family_id == @expected.fetch("family_id")
      raise Fence::OwnershipChanged, "Questrade credential session cannot change source"
    end
  end

  def assert_current!
    raise Fence::OwnershipChanged, "Questrade credential session is closed" if @closed
    raise Fence::OwnershipChanged, "Questrade credential session changed database" unless @database.equal?(ApplicationRecord.connection)
    unless item.id == @item_id && item.family_id == @expected.fetch("family_id")
      raise Fence::OwnershipChanged, "Questrade credential session changed source"
    end
    Fence.with_item(item, operation: :credentials) do |current|
      current.reload
      unless !current.scheduled_for_deletion? && current.attributes.slice(*CREDENTIAL_FIELDS) == @expected
        raise Fence::OwnershipChanged, "Questrade credentials changed during the operation"
      end
      @item = current
      Fence.scoped_sync!(current, @sync, allow_completed: @allow_completed) if @sync
    end
    true
  end

  def bind_sync!(sync, allow_completed:)
    return unless sync
    raise Fence::OwnershipChanged, "Questrade session cannot change its Sync" if @sync && @sync.id != sync.id
    @allow_completed = @sync ? @allow_completed && allow_completed : allow_completed
    @sync = sync
  end

  def provider
    assert_current!
    assert_usable!
    @provider ||= Provider::Questrade.new(refresh_token: item.refresh_token, api_server: item.api_server,
      admit_request: method(:admit_request!), synchronize_exchange: method(:exchange), on_token_refresh: method(:persist!))
  end

  def replace!(attributes)
    values = attributes.to_h.stringify_keys
    unless (values.keys - %w[name refresh_token status]).empty?
      raise ArgumentError, "Unsupported Questrade configuration"
    end
    values["api_server"] = nil if values["refresh_token"].present?
    values["status"] = "good" if values["refresh_token"].present?
    mutate! { item.assign_attributes(values) }
    item
  end

  def require_update!
    mutate! { item.status = :requires_update }
  end

  def close!
    @closed = true
  end

  def after_release(&block)
    (@after_release ||= []) << block
  end

  def dispatch!
    @after_release&.each(&:call)
  end

  def inspect
    "#<#{self.class.name}>"
  end

  private
    def assert_usable!
      unless item.good? && item.refresh_token.present?
        raise Provider::Questrade::AuthenticationError.new("Questrade requires a replacement refresh token", :reauth_required)
      end
    end

    def admit_request!
      raise Fence::InvalidSource, "Questrade HTTP cannot run inside a transaction" unless @database.open_transactions.zero?
      assert_current!
      assert_usable! unless @refreshing
    end

    def exchange
      admit_request!
      token = item.refresh_token
      # This committed refusal state survives a killed worker or ambiguous POST.
      # Only this session's validated replacement or explicit user replacement
      # can restore good; no durable full refresh journal is claimed here.
      mutate! { item.status = :requires_update }
      @refreshing = true
      yield token
    ensure
      @refreshing = false
    end

    def persist!(credentials)
      raise Fence::OwnershipChanged, "Questrade rotation has no active exchange" unless @refreshing
      mutate! do
        item.assign_attributes(refresh_token: credentials.fetch(:refresh_token), api_server: credentials.fetch(:api_server), status: :good)
      end
    end

    def mutate!
      raise Fence::InvalidSource, "Questrade credentials must commit outside an enclosing transaction" unless @database.open_transactions.zero?
      assert_current!
      item.with_lock do
        assert_current!
        yield
        item.save!
      end
      @expected = item.attributes.slice(*CREDENTIAL_FIELDS)
    end
end
