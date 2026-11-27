require "test_helper"

class Ai::Instrumentation::RedactorTest < ActiveSupport::TestCase
  test "a URL loses its credentials, query and fragment" do
    assert_equal "https://llm.example.test/v1", Ai::Instrumentation::Redactor.url("https://user:pass@llm.example.test/v1?key=abc#top")
  end

  test "a URL that doesn't parse is masked whole, since its credentials can't be found reliably" do
    assert_equal "[REDACTED]", Ai::Instrumentation::Redactor.url("http://user:pa/ss@llm example/v1?key=abc")
  end

  test "a blank URL stays nil" do
    assert_nil Ai::Instrumentation::Redactor.url("")
  end
end
