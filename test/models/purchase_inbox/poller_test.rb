require "test_helper"

class PurchaseInbox::PollerTest < ActiveSupport::TestCase
  FetchData = Struct.new(:attr)

  # Stands in for Net::IMAP: holds messages by UID and records what the poller did to them.
  class FakeImap
    attr_reader :calls, :seen, :moved, :deleted, :created

    def initialize(messages:, capabilities: %w[IMAP4REV1 MOVE], authserv_header: nil)
      @messages = messages
      @capabilities = capabilities
      @calls = []
      @seen = []
      @moved = []
      @deleted = []
      @created = []
    end

    def login(user, password) = @calls << [ :login, user, password ]
    def select(folder) = @calls << [ :select, folder ]
    def uid_search(_keys) = @messages.keys
    def capability = @capabilities
    def logout = @calls << [ :logout ]
    def disconnect = @calls << [ :disconnect ]
    def expunge = @calls << [ :expunge ]
    def uid_expunge(uid) = @calls << [ :uid_expunge, uid ]
    def create(folder) = @created << folder

    def uid_fetch(uid, attrs)
      raw = @messages.fetch(uid)
      @calls << [ :uid_fetch, uid, attrs ]
      if attrs == [ "RFC822.SIZE" ]
        [ FetchData.new({ "RFC822.SIZE" => raw.bytesize }) ]
      elsif attrs == "BODY.PEEK[HEADER.FIELDS (AUTHENTICATION-RESULTS)]"
        headers = raw.split(/\r?\n\r?\n/, 2).first.lines.chunk_while { |_, line| line.start_with?(" ", "\t") }
                     .select { _1.first.match?(/\AAuthentication-Results:/i) }.join
        [ FetchData.new({ "BODY[HEADER.FIELDS (AUTHENTICATION-RESULTS)]" => "#{headers}\r\n" }) ]
      else
        [ FetchData.new({ "BODY[]" => raw }) ]
      end
    end

    def uid_store(uid, _op, flags)
      @seen << uid if flags.include?(:Seen)
      @deleted << uid if flags.include?(:Deleted)
    end

    def uid_move(uid, folder) = @moved << [ uid, folder ]
    def uid_copy(uid, folder) = @moved << [ uid, folder ]
  end

  setup do
    @raw = file_fixture("purchase_emails/amazon_manual_forward.eml").read
    @config = PurchaseInbox::Config.new(
      enabled: true, host: "imap.example.com", port: 993, ssl: true, username: "orders@example.com",
      password: "secret", folder: "INBOX", processed_folder: "Sure/Processed", shop_domains: [ "amazon.com" ],
      authserv_id: "mx.google.com", require_sender_auth: true
    )
  end

  test "stores unseen messages as inbound emails, marks them seen and moves them" do
    imap = FakeImap.new(messages: { 7 => @raw })

    assert_difference -> { ActionMailbox::InboundEmail.count }, 1 do
      assert_equal 1, poll(imap)
    end

    assert_equal [ 7 ], imap.seen
    assert_equal [ [ 7, "Sure/Processed" ] ], imap.moved
    assert_equal [ "Sure/Processed" ], imap.created
    assert_includes imap.calls, [ :login, "orders@example.com", "secret" ]
    assert_includes imap.calls, [ :select, "INBOX" ]
    assert_includes imap.calls, [ :logout ]
  end

  test "without MOVE it copies and expunges only the processed message when the server has UIDPLUS" do
    imap = FakeImap.new(messages: { 7 => @raw }, capabilities: %w[IMAP4REV1 UIDPLUS])

    poll(imap)

    assert_equal [ [ 7, "Sure/Processed" ] ], imap.moved
    assert_equal [ 7 ], imap.deleted
    assert_includes imap.calls, [ :uid_expunge, 7 ]
    assert_not_includes imap.calls, [ :expunge ]
  end

  # A mailbox-wide EXPUNGE would also remove messages another client marked deleted.
  test "without MOVE or UIDPLUS it only copies, leaving the read message in place" do
    imap = FakeImap.new(messages: { 7 => @raw }, capabilities: %w[IMAP4REV1])

    poll(imap)

    assert_equal [ [ 7, "Sure/Processed" ] ], imap.moved
    assert_empty imap.deleted
    assert_not_includes imap.calls, [ :expunge ]
  end

  test "a server that stops answering ends the session and disconnects" do
    imap = FakeImap.new(messages: { 7 => @raw })
    def imap.login(*) = sleep(5)
    def imap.logout = sleep(5)
    poller = PurchaseInbox::Poller.new(config: @config, imap_factory: ->(_c) { imap })
    poller.stubs(:session_timeout).returns(0.1)
    poller.stubs(:logout_timeout).returns(0.1)

    assert_raises(Timeout::Error) { poller.poll! }
    assert_includes imap.calls, [ :disconnect ]
  end

  test "a broken connection at logout still disconnects" do
    imap = FakeImap.new(messages: {})
    def imap.logout = raise(Errno::EPIPE)

    poll(imap)

    assert_includes imap.calls, [ :disconnect ]
  end

  test "skips and marks seen a message that's too large" do
    imap = FakeImap.new(messages: { 7 => "x" * (PurchaseInbox::Poller::MAX_BYTES + 1) })

    assert_no_difference -> { ActionMailbox::InboundEmail.count } do
      assert_equal 0, poll(imap)
    end
    assert_equal [ 7 ], imap.seen
  end

  test "a message already received is not stored twice" do
    poll(FakeImap.new(messages: { 7 => @raw }))

    assert_no_difference -> { ActionMailbox::InboundEmail.count } do
      poll(FakeImap.new(messages: { 8 => @raw }))
    end
  end

  test "takes at most fifty messages per run" do
    messages = (1..55).to_h { |uid| [ uid, @raw.sub(/Message-ID: <[^>]+>/, "Message-ID: <m#{uid}@fixture.example>") ] }
    imap = FakeImap.new(messages:)

    assert_equal 50, poll(imap)
  end

  test "test_connection reports the message count and the authentication hosts on the latest message" do
    imap = FakeImap.new(messages: { 7 => @raw })
    def imap.status(_folder, _attrs) = { "MESSAGES" => 3 }

    result = PurchaseInbox::Poller.test_connection(config: @config, imap_factory: ->(_c) { imap })

    assert result[:ok]
    assert_equal 3, result[:message_count]
    assert_equal [ "mx.google.com" ], result[:authserv_ids]
    fetched = imap.calls.select { _1.first == :uid_fetch }.map(&:last)
    assert_equal [ "BODY.PEEK[HEADER.FIELDS (AUTHENTICATION-RESULTS)]" ], fetched
  end

  test "test_connection reports a login error without the password" do
    imap = FakeImap.new(messages: {})
    def imap.login(*) = raise(Net::IMAP::NoResponseError.new(Struct.new(:data).new(Struct.new(:text).new("Invalid credentials: secret"))))

    result = PurchaseInbox::Poller.test_connection(config: @config, imap_factory: ->(_c) { imap })

    assert_not result[:ok]
    assert_match "Invalid credentials", result[:error]
    refute_includes result[:error], "secret"
  end

  private
    def poll(imap)
      PurchaseInbox::Poller.new(config: @config, imap_factory: ->(_c) { imap }).poll!
    end
end
