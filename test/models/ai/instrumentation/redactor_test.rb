require "test_helper"

class Ai::Instrumentation::RedactorTest < ActiveSupport::TestCase
  test "a URL loses its credentials, query and fragment" do
    assert_equal "https://llm.example.test/v1", Ai::Instrumentation::Redactor.url("https://user:pass@llm.example.test/v1?key=abc#top")
  end

  test "a URL that doesn't parse still loses its credentials and query" do
    assert_equal "http://llm example/v1", Ai::Instrumentation::Redactor.url("http://user:pass@llm example/v1?key=abc")
  end

  test "a blank URL stays nil" do
    assert_nil Ai::Instrumentation::Redactor.url("")
  end
end
