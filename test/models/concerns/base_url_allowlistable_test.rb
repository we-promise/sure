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

  # URL-shape validation at declaration time — fail-closed against SSRF
  # footguns in the fallback `effective_base_url` path.

  test "rejects http:// (non-HTTPS)" do
    klass = anonymous_class(name: "HttpAllowlistItem")
    assert_raises(ArgumentError) do
      klass.class_eval { allowed_base_urls "http://insecure.example.com/api" }
    end
  end

  test "rejects relative paths" do
    klass = anonymous_class(name: "RelativeAllowlistItem")
    assert_raises(ArgumentError) do
      klass.class_eval { allowed_base_urls "/api/v1" }
    end
  end

  test "rejects URLs with embedded userinfo" do
    klass = anonymous_class(name: "UserinfoAllowlistItem")
    assert_raises(ArgumentError) do
      klass.class_eval { allowed_base_urls "https://admin:secret@internal.example.com/api" }
    end
  end

  test "rejects URLs with a query string" do
    klass = anonymous_class(name: "QueryAllowlistItem")
    assert_raises(ArgumentError) do
      klass.class_eval { allowed_base_urls "https://api.example.com/v1?secret=1" }
    end
  end

  test "rejects URLs with a fragment" do
    klass = anonymous_class(name: "FragmentAllowlistItem")
    assert_raises(ArgumentError) do
      klass.class_eval { allowed_base_urls "https://api.example.com/v1#frag" }
    end
  end

  test "rejects syntactically invalid URIs" do
    klass = anonymous_class(name: "InvalidAllowlistItem")
    assert_raises(ArgumentError) do
      klass.class_eval { allowed_base_urls "https://exa mple.com/api" }
    end
  end

  test "accepts a plain absolute HTTPS URL with path" do
    klass = anonymous_class(name: "ValidAllowlistItem")
    assert_nothing_raised do
      klass.class_eval { allowed_base_urls "https://api.example.com/v1" }
    end
  end
end
