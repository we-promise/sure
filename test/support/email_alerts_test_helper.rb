# Synthetic alert emails in test/fixtures/files/email_alerts copy the layout of
# real bank alerts with made-up data. They are DKIM-signed (relaxed/relaxed,
# selector "sure-test") by an independent implementation with a throwaway key
# whose public half is in dkim_test_key.txt.
module EmailAlertsTestHelper
  FIXTURE_DIR = Rails.root.join("test/fixtures/files/email_alerts")

  def email_alert_fixture(name)
    File.binread(FIXTURE_DIR.join("#{name}.eml"))
  end

  def dkim_test_key_resolver
    record = File.read(FIXTURE_DIR.join("dkim_test_key.txt")).strip
    ->(selector, _domain) { selector == "sure-test" ? record : nil }
  end

  # Routes DKIM key lookups to the test key for the duration of the test.
  def stub_dkim_dns!
    EmailAlert::DkimVerifier::KeyResolver.any_instance.stubs(:call).with { |selector, _| selector == "sure-test" }
      .returns(File.read(FIXTURE_DIR.join("dkim_test_key.txt")).strip)
  end
end
