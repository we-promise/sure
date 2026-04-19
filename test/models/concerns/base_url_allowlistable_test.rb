require "test_helper"

class BaseUrlAllowlistableTest < ActiveSupport::TestCase
  # Helper: build a throwaway class that can host the concern without
  # persistence — just enough to exercise the DSL surface.
  def anonymous_class(name: "TestAllowlistItem")
    klass = Class.new do
      include ActiveModel::Validations
      include BaseUrlAllowlistable
    end
    klass.define_singleton_method(:name) { name }
    klass
  end

  test "raises if allowed_base_urls is declared twice on the same class" do
    # A second call would previously leave ALLOWED_BASE_URLS stale (const_set
    # is guarded) while appending a second `validates` with the new list —
    # the model and validator could silently disagree. Now we fail loudly.
    klass = anonymous_class
    klass.class_eval { allowed_base_urls "https://first.example.com" }

    assert_raises(ArgumentError, "should reject double configuration") do
      klass.class_eval { allowed_base_urls "https://second.example.com" }
    end
  end

  test "raises when the allowlist is empty" do
    klass = anonymous_class(name: "EmptyAllowlistItem")
    assert_raises(ArgumentError) { klass.class_eval { allowed_base_urls } }
  end

  test "raises when the allowlist contains non-string entries" do
    klass = anonymous_class(name: "NonStringAllowlistItem")
    assert_raises(ArgumentError) do
      klass.class_eval { allowed_base_urls "https://ok.example.com", :symbol }
    end
  end

  test "raises when the allowlist contains blank strings" do
    klass = anonymous_class(name: "BlankAllowlistItem")
    assert_raises(ArgumentError) do
      klass.class_eval { allowed_base_urls "https://ok.example.com", "" }
    end
  end

  test "raises when the allowlist contains nil" do
    klass = anonymous_class(name: "NilAllowlistItem")
    assert_raises(ArgumentError) do
      klass.class_eval { allowed_base_urls "https://ok.example.com", nil }
    end
  end
end
