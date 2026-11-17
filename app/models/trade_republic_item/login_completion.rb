# Finishing a push login, shared by the browser poll and the scheduled
# re-login so both treat a duplicate connection and a superseded login alike.
module TradeRepublicItem::LoginCompletion
  extend ActiveSupport::Concern

  UNGUARDED = Object.new.freeze

  # Cancellation or a newer login can replace the pending state while a poll
  # is in flight; only the poll that started from the current state may write.
  # A scheduled login also passes its schedule token, so it stops writing once
  # auto login was changed or switched off.
  def update_if_pending_login_current!(expected_pending, token: nil, **attributes)
    with_lock do
      current = login_current?(expected_pending, token)
      update!(attributes) if current
      current
    end
  end

  # Stores the session of a confirmed login. Returns :completed, :duplicate
  # (the account belongs to another connection, so this one was discarded) or
  # :superseded (a newer login owns the item; nothing was written).
  def finish_login(expected_pending, result, token: nil)
    return discard_duplicate_connection!(expected_pending, token: token) ? :duplicate : :superseded if duplicate_connection?(result)

    begin
      return :superseded unless update_if_pending_login_current!(
        expected_pending,
        token: token,
        session_blob: result.data.fetch("session_txt"),
        pending_login_state: nil,
        status: :good,
        brokerage_account_id: login_account_id(result)
      )
    rescue ActiveRecord::RecordNotUnique
      return discard_duplicate_connection!(expected_pending, token: token) ? :duplicate : :superseded
    end

    :completed
  end

  def login_account_id(result)
    result.data.dig("account", "brokerage_account_id").presence
  end

  # Connecting the same Trade Republic account through a second item would
  # import its accounts twice. trade_republic_accounts rows only exist once the
  # importer's first sync runs, so checking only those would let a second item
  # finish login for the same account in the gap before that job runs (or truly
  # concurrently). brokerage_account_id is written on the item itself the
  # moment login succeeds and is backed by a unique index, so this is an
  # early, user-facing check; the index (see finish_login) is what actually
  # closes the race.
  def duplicate_connection?(result)
    account_id = login_account_id(result)
    return false if account_id.blank?

    other_active_items.exists?(brokerage_account_id: account_id) ||
      other_active_items
        .joins(:trade_republic_accounts)
        .where(trade_republic_accounts: { trade_republic_account_id: [ account_id, "cash:#{account_id}" ] })
        .exists?
  end

  # Without expected_pending the item is discarded unconditionally (the
  # controller paths that already hold the login). With it, a login or schedule
  # that took over in the meantime is left alone and false is returned.
  def discard_duplicate_connection!(expected_pending = UNGUARDED, token: nil)
    with_lock do
      next false unless expected_pending.equal?(UNGUARDED) || login_current?(expected_pending, token)

      # A failed unique-index write from the losing update! left brokerage_account_id
      # dirty on the in-memory record with the other item's value; clear it
      # explicitly or this update! would collide with the same index again.
      update!(session_blob: nil, pending_login_state: nil, status: :requires_update, brokerage_account_id: nil, pin: nil, auto_login_time: nil)
      destroy_later if trade_republic_accounts.none?
      true
    end
  end

  private

    def login_current?(expected_pending, token)
      return false unless pending_login_state.presence == expected_pending.presence

      token.nil? || (auto_login_token == token && auto_login_time.present?)
    end

    def other_active_items
      family.trade_republic_items.active.where.not(id: id)
    end
end
