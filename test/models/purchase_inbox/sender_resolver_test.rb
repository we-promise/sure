require "test_helper"

class PurchaseInbox::SenderResolverTest < ActiveSupport::TestCase
  setup do
    @config = inbox_config
  end

  test "a manual forward is routed by the sender address" do
    result = resolve(fixture("amazon_manual_forward.eml"))

    assert_nil result.reason
    assert_equal users(:family_admin), result.user
    assert_equal "sender", result.route_kind
  end

  test "an automatic forward is routed by the plus tag when the shop is allowed" do
    result = resolve(fixture("amazon_auto_forward.eml"))

    assert_nil result.reason
    assert_equal users(:family_admin), result.user
    assert_equal "tag", result.route_kind
  end

  test "a plus tag from a domain that isn't an allowed shop is unknown" do
    @config = inbox_config(shop_domains: [ "allegro.pl" ])

    assert_equal "unknown_sender", resolve(fixture("amazon_auto_forward.eml")).reason
  end

  test "a shop subdomain is allowed but a look-alike domain isn't" do
    assert_nil resolve(auto_forward(from: "orders@mail.amazon.com", header_d: "amazon.com")).reason
    assert_equal "unknown_sender", resolve(auto_forward(from: "orders@amazon.com.evil.example", header_d: "amazon.com.evil.example")).reason
  end

  test "an unknown sender without a tag is unknown" do
    mail = Mail.new(fixture("amazon_manual_forward.eml"))
    mail.from = "stranger@example.com"

    assert_equal "unknown_sender", resolve(mail.to_s).reason
  end

  test "a result from an untrusted authentication host doesn't count" do
    @config = inbox_config(authserv_id: "mx.other.example")

    assert_equal "sender_not_authenticated", resolve(fixture("amazon_manual_forward.eml")).reason
  end

  test "a missing Authentication-Results header fails authentication" do
    mail = Mail.new(fixture("amazon_manual_forward.eml"))
    mail.header["Authentication-Results"] = nil

    assert_equal "sender_not_authenticated", resolve(mail.to_s).reason
  end

  test "DKIM for another domain fails authentication" do
    mail = Mail.new(fixture("amazon_manual_forward.eml"))
    mail.header["Authentication-Results"] = nil
    mail.header["Authentication-Results"] = "mx.google.com; dkim=pass header.d=other.example; dmarc=fail header.from=bobdylan.com"

    assert_equal "sender_not_authenticated", resolve(mail.to_s).reason
  end

  test "DKIM aligned with the sender's domain passes without DMARC" do
    mail = Mail.new(fixture("amazon_manual_forward.eml"))
    mail.header["Authentication-Results"] = nil
    mail.header["Authentication-Results"] = "mx.google.com; dkim=pass header.d=bobdylan.com; dmarc=none"

    assert_nil resolve(mail.to_s).reason
  end

  test "the topmost trusted header wins over a forged one further down" do
    raw = fixture("amazon_manual_forward.eml").sub(
      "Authentication-Results:",
      "Authentication-Results: mx.google.com; dkim=fail; dmarc=fail header.from=bobdylan.com\nX-Placeholder: 1\nAuthentication-Results:"
    )

    assert_equal "sender_not_authenticated", resolve(raw).reason
  end

  test "an ARC pass alone doesn't authenticate the sender" do
    assert_equal "sender_not_authenticated", resolve(with_results("mx.google.com; arc=pass (i=1); dkim=none; dmarc=none")).reason
  end

  test "DMARC must name the sender's domain" do
    assert_equal "sender_not_authenticated", resolve(with_results("mx.google.com; dmarc=pass")).reason
    assert_equal "sender_not_authenticated", resolve(with_results("mx.google.com; dmarc=pass header.from=other.example")).reason
  end

  test "an email with several From addresses is not authenticated" do
    mail = Mail.new(fixture("amazon_manual_forward.eml"))
    mail.from = [ "bob@bobdylan.com", "mallory@evil.example" ]

    assert_equal "sender_not_authenticated", resolve(mail.to_s).reason
  end

  test "a plus tag in To or Cc doesn't route the email" do
    mail = Mail.new(fixture("amazon_auto_forward.eml"))
    mail.header["Delivered-To"] = nil
    mail.header["X-Forwarded-To"] = nil
    mail.to = "orders+bob@example.com"

    assert_equal "unknown_sender", resolve(mail.to_s).reason
  end

  test "a plus tag on another mailbox's address doesn't route the email" do
    raw = fixture("amazon_auto_forward.eml").gsub("orders+bob@example.com", "someone+bob@elsewhere.example")

    assert_equal "unknown_sender", resolve(raw).reason
  end

  test "only the topmost Delivered-To counts" do
    raw = fixture("amazon_auto_forward.eml")
      .sub("Delivered-To: orders+bob@example.com", "Delivered-To: orders@example.com\nDelivered-To: orders+bob@example.com")
      .sub(/^X-Forwarded-To: .*\n/, "")

    assert_equal "unknown_sender", resolve(raw).reason
  end

  test "X-Original-To written by the sender doesn't route the email" do
    raw = fixture("amazon_auto_forward.eml")
      .sub("Delivered-To: orders+bob@example.com", "Delivered-To: orders@example.com\nX-Original-To: orders+bob@example.com")

    assert_equal "unknown_sender", resolve(raw).reason
  end

  test "authentication can be turned off" do
    @config = inbox_config(require_sender_auth: false)
    mail = Mail.new(fixture("amazon_manual_forward.eml"))
    mail.header["Authentication-Results"] = nil

    assert_nil resolve(mail.to_s).reason
  end

  private
    def resolve(raw)
      PurchaseInbox::SenderResolver.new(Mail.new(raw), config: @config).result
    end

    def fixture(name)
      file_fixture("purchase_emails/#{name}").read
    end

    def with_results(value)
      mail = Mail.new(fixture("amazon_manual_forward.eml"))
      mail.header["Authentication-Results"] = nil
      mail.header["Authentication-Results"] = value
      mail.to_s
    end

    def auto_forward(from:, header_d:)
      mail = Mail.new(fixture("amazon_auto_forward.eml"))
      mail.from = from
      mail.header["Authentication-Results"] = nil
      mail.header["Authentication-Results"] = "mx.google.com; dkim=pass header.d=#{header_d}; dmarc=pass header.from=#{header_d}"
      mail.to_s
    end

    def inbox_config(**overrides)
      PurchaseInbox::Config.new(**{
        enabled: true, host: "imap.example.com", port: 993, ssl: true, username: "orders@example.com",
        password: "secret", folder: "INBOX", processed_folder: "Sure/Processed", shop_domains: [ "amazon.com" ],
        authserv_id: "mx.google.com", require_sender_auth: true
      }.merge(overrides))
    end
end
