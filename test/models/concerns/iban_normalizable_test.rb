require "test_helper"

class IbanNormalizableTest < ActiveSupport::TestCase
  test "strips spaces and upcases" do
    assert_equal "DE89370400440532013000", IbanNormalizable.normalize("de89 3704 0044 0532 0130 00") # pipelock:ignore IBAN
  end

  test "strips tabs, newlines, and non-breaking spaces" do
    assert_equal "DE89370400440532013000", IbanNormalizable.normalize("de89\t3704\n0044 0532 0130 00") # pipelock:ignore IBAN
  end

  test "strips dots" do
    assert_equal "DE89370400440532013000", IbanNormalizable.normalize("DE89.3704.0044.0532.0130.00") # pipelock:ignore IBAN
  end

  test "strips dashes" do
    assert_equal "DE89370400440532013000", IbanNormalizable.normalize("DE89-3704-0044-0532-0130-00") # pipelock:ignore IBAN
  end

  test "strips any other punctuation, keeping only letters and digits" do
    assert_equal "DE89370400440532013000", IbanNormalizable.normalize("DE89/3704:0044,0532;0130'00") # pipelock:ignore IBAN
  end

  test "leaves a blank value as nil" do
    assert_nil IbanNormalizable.normalize("")
    assert_nil IbanNormalizable.normalize(nil)
    assert_nil IbanNormalizable.normalize("   ")
    assert_nil IbanNormalizable.normalize("...")
  end
end
