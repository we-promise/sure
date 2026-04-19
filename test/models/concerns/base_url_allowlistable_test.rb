require "test_helper"

class BaseUrlAllowlistableTest < ActiveSupport::TestCase
  test "raises if allowed_base_urls is declared twice on the same class" do
    # A second call would previously leave ALLOWED_BASE_URLS stale (const_set
    # is guarded) while appending a second `validates` with the new list —
    # the model and validator could silently disagree. Now we fail loudly.
    klass = Class.new do
      include ActiveModel::Validations
      include BaseUrlAllowlistable
      def self.name
        "TestAllowlistItem"
      end
      allowed_base_urls "https://first.example.com"
    end

    assert_raises(ArgumentError, "should reject double configuration") do
      klass.class_eval do
        allowed_base_urls "https://second.example.com"
      end
    end
  end
end
