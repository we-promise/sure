require "test_helper"

class PurchasesMailboxTest < ActionMailbox::TestCase
  include ActionMailer::TestHelper

  setup do
    @user = users(:family_admin)
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    PurchaseInbox.stubs(:config).returns(PurchaseInbox::Config.new(
      enabled: true, host: "imap.example.com", port: 993, ssl: true, username: "orders@example.com",
      password: "secret", folder: "INBOX", processed_folder: "Sure/Processed", shop_domains: [ "amazon.com" ],
      authserv_id: "mx.google.com", require_sender_auth: true
    ))
  end

  test "a routed, authenticated email creates a processing purchase and starts reading it" do
    purchase = nil
    assert_enqueued_with(job: Purchase::EmailProcessJob) do
      inbound = receive_inbound_email_from_source(fixture("amazon_manual_forward.eml"))
      assert inbound.delivered?
      purchase = Purchase.order(:created_at).last
    end

    assert_equal "processing", purchase.status
    assert_equal "email", purchase.source
    assert_equal @user, purchase.user
    assert_equal @user.family, purchase.family
    assert purchase.original_email.attached?
    assert_equal "message/rfc822", purchase.original_email.content_type
    assert_includes purchase.original_email.download, "Order Total: $249.99"
  end

  test "an email whose original can't be stored leaves no purchase behind" do
    ActiveStorage::Attached::One.any_instance.stubs(:attach).raises(ActiveStorage::IntegrityError)

    assert_no_difference "Purchase.count" do
      assert_raises(ActiveStorage::IntegrityError) do
        receive_inbound_email_from_source(fixture("amazon_manual_forward.eml"))
      end
    end
  end

  test "a purchase goes to the family its owner is in when it's created" do
    stale = User.find(@user.id)
    PurchaseInbox::SenderResolver.any_instance.stubs(:result)
      .returns(PurchaseInbox::SenderResolver::Result.new(user: stale, route_kind: :sender, reason: nil))
    other_family = families(:empty)
    User.where(id: @user.id).update_all(family_id: other_family.id)

    receive_inbound_email_from_source(fixture("amazon_manual_forward.eml"))

    assert_equal other_family, Purchase.order(:created_at).last.family
  end

  test "routing the same email again reuses its purchase" do
    inbound = receive_inbound_email_from_source(fixture("amazon_manual_forward.eml"))

    assert_no_difference "Purchase.count" do
      inbound.pending!
      inbound.route
    end
    assert_equal 1, Purchase.where(inbound_email_message_id: inbound.message_id).count
  end

  test "an original whose upload fails after the commit fails the purchase, and routing again recovers it" do
    inbound = create_inbound_email_from_source(fixture("amazon_manual_forward.eml"))
    ActiveStorage::Attached::Changes::CreateOne.any_instance.stubs(:upload).raises(StandardError, "storage down")

    assert_raises(StandardError) { inbound.route }
    purchase = Purchase.find_by!(inbound_email_message_id: inbound.message_id)
    assert purchase.failed?
    assert_match "storage down", purchase.error

    ActiveStorage::Attached::Changes::CreateOne.any_instance.unstub(:upload)
    assert_enqueued_with(job: Purchase::EmailProcessJob) do
      inbound.reload.pending!
      inbound.route
    end
    assert purchase.reload.processing?
    assert purchase.original_email.attached?
    assert_equal 1, Purchase.where(inbound_email_message_id: inbound.message_id).count
  end

  test "a purchase whose reading can't be queued is failed, so it can be read again" do
    Purchase::EmailProcessJob.stubs(:perform_later).raises(RedisClient::CannotConnectError)

    receive_inbound_email_from_source(fixture("amazon_manual_forward.eml"))

    purchase = Purchase.order(:created_at).last
    assert purchase.failed?
    assert purchase.original_email.attached?
  end

  test "an automatically forwarded order to a plus address is accepted" do
    assert_difference -> { Purchase.count }, 1 do
      receive_inbound_email_from_source(fixture("amazon_auto_forward.eml"))
    end
  end

  test "an unknown sender is bounced silently and logged" do
    raw = fixture("amazon_manual_forward.eml").sub("From: Bob Dylan <bob@bobdylan.com>", "From: someone@example.com")

    assert_no_enqueued_emails do
      assert_no_difference -> { Purchase.count } do
        inbound = receive_inbound_email_from_source(raw)
        assert inbound.bounced?
      end
    end

    entry = DebugLogEntry.where(source: "PurchasesMailbox").last
    assert_equal "unknown_sender", entry.metadata["reason"]
    assert_equal "someone@example.com", entry.metadata["from"]
    assert_equal "Fwd: Your Amazon.com order #112-1234567-1234567", entry.metadata["subject"]
  end

  test "failed authentication bounces and logs the reason" do
    raw = fixture("amazon_manual_forward.eml").gsub("dmarc=pass", "dmarc=fail").gsub("dkim=pass", "dkim=fail")

    inbound = receive_inbound_email_from_source(raw)

    assert inbound.bounced?
    assert_equal "sender_not_authenticated", DebugLogEntry.where(source: "PurchasesMailbox").last.metadata["reason"]
  end

  test "a user without preview features gets one notice a day and nothing is created" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))

    assert_no_difference -> { Purchase.count } do
      assert_enqueued_email_with PurchaseMailer, :preview_required, params: { user: @user } do
        assert receive_inbound_email_from_source(fixture("amazon_manual_forward.eml")).bounced?
      end
      assert_no_enqueued_emails do
        receive_inbound_email_from_source(fixture("amazon_manual_forward.eml").sub(/Message-ID: <[^>]+>/, "Message-ID: <second@fixture.example>"))
      end
    end
  end

  private
    def fixture(name)
      file_fixture("purchase_emails/#{name}").read
    end
end
