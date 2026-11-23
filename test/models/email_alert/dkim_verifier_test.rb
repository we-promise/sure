require "test_helper"

class EmailAlert::DkimVerifierTest < ActiveSupport::TestCase
  include EmailAlertsTestHelper

  test "verifies signatures made by an independent signer" do
    %w[gtbank_credit opay_transfer grey_card].each do |name|
      verifier = verifier_for(email_alert_fixture(name))

      assert verifier.results.all?(&:pass?), "#{name}: #{verifier.results.map(&:reason)}"
    end
  end

  test "accepts the signing domain and its subdomains only" do
    verifier = verifier_for(email_alert_fixture("gtbank_credit"))

    assert verifier.passes_for?("gtbank.com")
    assert verifier.passes_for?("alerts.gtbank.com")
    assert_not verifier.passes_for?("gtbank.com.evil.example")
    assert_not verifier.passes_for?("com")
  end

  test "fails when the body was changed after signing" do
    raw = email_alert_fixture("gtbank_credit").sub("250000", "950000")

    result = verifier_for(raw).results.first
    assert_equal :fail, result.status
    assert_equal "body hash mismatch", result.reason
  end

  test "fails when a signed header was changed" do
    raw = email_alert_fixture("gtbank_credit").sub("Subject: Transaction Notification", "Subject: Transaction Notificatio")

    result = verifier_for(raw).results.first
    assert_equal :fail, result.status
    assert_equal "signature mismatch", result.reason
  end

  test "tolerates headers added above the signature by forwarding" do
    raw = "Received: by relay.example; Mon, 23 Nov 2026 10:00:00 +0000\r\nX-Forwarded-For: someone@example.com\r\n".b +
          email_alert_fixture("opay_transfer")

    assert verifier_for(raw).passes_for?("opay-nigeria.com")
  end

  test "reports a missing DNS key as a temporary error" do
    verifier = EmailAlert::DkimVerifier.new(email_alert_fixture("grey_card"), key_resolver: ->(_s, _d) { nil })

    assert_equal :temperror, verifier.results.first.status
    assert_not verifier.passes_for?("grey.co")
  end

  test "rejects signatures that use the body length tag" do
    raw = email_alert_fixture("gtbank_credit").sub("DKIM-Signature: v=1;", "DKIM-Signature: v=1; l=10;")

    assert_equal "l= tag not accepted", verifier_for(raw).results.first.reason
  end

  test "finds no signature on unsigned mail" do
    raw = "From: GeNS@gtbank.com\r\nSubject: Transaction Notification\r\n\r\nhello\r\n"

    assert_empty verifier_for(raw).results
    assert_not verifier_for(raw).passes_for?("gtbank.com")
  end

  private

    def verifier_for(raw)
      EmailAlert::DkimVerifier.new(raw, key_resolver: dkim_test_key_resolver)
    end
end
