# Fetches new messages from the order mailbox over IMAP and hands each to Action Mailbox. A
# fetched message is marked seen and moved to the processed folder (copied, where the server
# can't move or expunge a single message), so it is read once.
class PurchaseInbox::Poller
  MAX_MESSAGES = 50
  MAX_BYTES = 25.megabytes
  # net-imap waits for command responses without a deadline, so a server that keeps the
  # connection open but stops answering would hold the job (or the settings page) forever.
  SESSION_TIMEOUT = 5.minutes
  LOGOUT_TIMEOUT = 10.seconds
  DEFAULT_IMAP_FACTORY = ->(config) { Net::IMAP.new(config.host, port: config.port, ssl: config.ssl) }

  def self.test_connection(config: PurchaseInbox.config, imap_factory: DEFAULT_IMAP_FACTORY)
    new(config:, imap_factory:).test_connection
  end

  def initialize(config: PurchaseInbox.config, imap_factory: DEFAULT_IMAP_FACTORY)
    @config = config
    @imap_factory = imap_factory
  end

  # @return [Integer] messages stored as inbound emails
  def poll!
    session do |imap|
      imap.uid_search([ "UNSEEN" ]).first(MAX_MESSAGES).count { |uid| ingest(imap, uid) }
    end
  end

  # @return [Hash] ok:, message_count:, authserv_ids: (hosts that wrote Authentication-Results on
  #   the latest message, to help fill the trusted host), error:
  def test_connection
    session do |imap|
      count = imap.status(config.folder, [ "MESSAGES" ])["MESSAGES"]
      { ok: true, message_count: count, authserv_ids: latest_authserv_ids(imap), error: nil }
    end
  rescue Net::IMAP::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, Timeout::Error, IOError => e
    { ok: false, message_count: nil, authserv_ids: [], error: PurchaseInbox.redact(e.message, config.password) }
  end

  private
    attr_reader :config, :imap_factory

    def session
      imap = nil
      Timeout.timeout(session_timeout) do
        imap = imap_factory.call(config)
        imap.login(config.username, config.password)
        imap.select(config.folder)
        yield imap
      end
    ensure
      begin
        Timeout.timeout(logout_timeout) { imap&.logout }
      rescue Net::IMAP::Error, IOError, SystemCallError, OpenSSL::SSL::SSLError, Timeout::Error
        nil # the connection is going away either way
      ensure
        imap&.disconnect
      end
    end

    def session_timeout = SESSION_TIMEOUT

    def logout_timeout = LOGOUT_TIMEOUT

    def ingest(imap, uid)
      size = imap.uid_fetch(uid, [ "RFC822.SIZE" ])&.first&.attr&.fetch("RFC822.SIZE", 0).to_i
      if size > MAX_BYTES
        imap.uid_store(uid, "+FLAGS", [ :Seen ])
        Rails.logger.warn("PurchaseInbox: skipped message #{uid} of #{size} bytes")
        return false
      end

      raw = imap.uid_fetch(uid, "BODY.PEEK[]")&.first&.attr&.fetch("BODY[]", nil)
      return false if raw.blank?

      stored = store(raw)
      imap.uid_store(uid, "+FLAGS", [ :Seen ])
      move_to_processed(imap, uid)
      stored
    end

    def store(raw)
      ActionMailbox::InboundEmail.create_and_extract_message_id!(raw)
      true
    rescue ActiveRecord::RecordNotUnique
      false
    end

    def move_to_processed(imap, uid)
      folder = config.processed_folder
      return if folder.blank?

      ensure_folder(imap, folder)
      capabilities = Array(imap.capability).map(&:upcase)
      if capabilities.include?("MOVE")
        imap.uid_move(uid, folder)
      else
        imap.uid_copy(uid, folder)
        # Only UID EXPUNGE removes just this message; a plain EXPUNGE would also remove what
        # other clients marked deleted. Without it the read (and seen) message stays put.
        if capabilities.include?("UIDPLUS")
          imap.uid_store(uid, "+FLAGS", [ :Deleted ])
          imap.uid_expunge(uid)
        end
      end
    rescue Net::IMAP::Error => e
      Rails.logger.warn("PurchaseInbox: could not move message #{uid}: #{e.message}")
    end

    def ensure_folder(imap, folder)
      return if @folder_ready

      imap.create(folder)
    rescue Net::IMAP::NoResponseError
      nil # already exists
    ensure
      @folder_ready = true
    end

    def latest_authserv_ids(imap)
      uid = imap.uid_search([ "ALL" ]).last
      return [] unless uid

      # Only that header, not the whole message with its attachments. Servers echo the section
      # name in their own letter case.
      attr = imap.uid_fetch(uid, "BODY.PEEK[HEADER.FIELDS (AUTHENTICATION-RESULTS)]")&.first&.attr
      raw = attr&.find { |name, _| name.to_s.upcase.start_with?("BODY[HEADER.FIELDS") }&.last
      return [] if raw.blank?

      Array(Mail.new(raw).header["Authentication-Results"]).filter_map do |field|
        field.value.to_s.split(";").first.to_s.strip.split(/\s+/).first&.downcase
      end.uniq
    end
end
