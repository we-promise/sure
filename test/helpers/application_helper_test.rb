require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "#icon normalizes icon names to lowercase" do
    capture = []

    singleton_class.send(:define_method, :lucide_icon) do |key, **opts|
      capture << [ key, opts ]
      "<svg></svg>".html_safe
    end

    icon("Key")

    assert_equal "key", capture.first.first
  ensure
    singleton_class.send(:remove_method, :lucide_icon) if singleton_class.method_defined?(:lucide_icon)
  end

  test "#icon falls back when lucide icon is unknown" do
    calls = []

    singleton_class.send(:define_method, :lucide_icon) do |key, **_opts|
      calls << key
      raise ArgumentError, "Unknown icon #{key}" if key == "not-a-real-icon"

      "<svg></svg>".html_safe
    end

    result = icon("not-a-real-icon")

    assert_equal [ "not-a-real-icon", "key" ], calls
    assert_equal "<svg></svg>", result
  ensure
    singleton_class.send(:remove_method, :lucide_icon) if singleton_class.method_defined?(:lucide_icon)
  end

  test "#title(page_title)" do
    title("Test Title")
    assert_equal "Test Title", content_for(:title)
  end

  test "#header_title(page_title)" do
    header_title("Test Header Title")
    assert_equal "Test Header Title", content_for(:header_title)
  end

  test "#sidekiq_web_available? returns true when the route is mounted" do
    named_routes = Struct.new(:defined) do
      def route_defined?(name)
        defined.fetch(name)
      end
    end

    Rails.application.routes.stub(:named_routes, named_routes.new({ sidekiq_web_path: true })) do
      assert sidekiq_web_available?
    end
  end

  test "#sidekiq_web_available? returns false when the route is unavailable" do
    named_routes = Struct.new(:defined) do
      def route_defined?(name)
        defined.fetch(name, false)
      end
    end

    Rails.application.routes.stub(:named_routes, named_routes.new({})) do
      assert_not sidekiq_web_available?
    end
  end

  test "#sidekiq_web_available? returns true when only the url helper is defined" do
    named_routes = Struct.new(:defined) do
      def route_defined?(name)
        defined.fetch(name, false)
      end
    end

    Rails.application.routes.stub(:named_routes, named_routes.new({ sidekiq_web_url: true })) do
      assert sidekiq_web_available?
    end
  end

  def setup
    @account1 = Account.new(currency: "USD", balance: 1)
    @account2 = Account.new(currency: "USD", balance: 2)
    @account3 = Account.new(currency: "EUR", balance: -7)
  end

  test "#totals_by_currency(collection: collection, money_method: money_method)" do
    assert_equal "$3.00", totals_by_currency(collection: [ @account1, @account2 ], money_method: :balance_money)
    assert_equal "$3.00 | -€7.00", totals_by_currency(collection: [ @account1, @account2, @account3 ], money_method: :balance_money)
    assert_equal "", totals_by_currency(collection: [], money_method: :balance_money)
    assert_equal "$0.00", totals_by_currency(collection: [ Account.new(currency: "USD", balance: 0) ], money_method: :balance_money)
    assert_equal "-$3.00 | €7.00", totals_by_currency(collection: [ @account1, @account2, @account3 ], money_method: :balance_money, negate: true)
  end

  test "#currency_picker_options_for_family returns enabled family currencies" do
    family = families(:dylan_family)
    family.update!(currency: "SGD", enabled_currencies: [ "USD" ])

    assert_equal [ "SGD", "USD" ], currency_picker_options_for_family(family)
  end

  test "#currency_picker_options_for_family keeps selected legacy currency visible" do
    family = families(:dylan_family)
    family.update!(currency: "SGD", enabled_currencies: [ "USD" ])

    assert_equal [ "SGD", "USD", "EUR" ], currency_picker_options_for_family(family, extra: "EUR")
  end

  # `markdown` renders AI chat messages, and a user message is content the
  # user typed. Redcarpet passes raw HTML through untouched, so without a
  # filter this is stored XSS against anyone else in the family.
  test "markdown strips script tags from user content" do
    assert_no_match(/<script/i, markdown("<script>alert(1)</script>"))
  end

  test "markdown strips event handlers from user content" do
    assert_no_match(/onerror/i, markdown('<img src=x onerror="alert(1)">'))
  end

  # Raw HTML in a chat message must not survive, and stripping tags is not
  # enough on its own: div, span and class stay allow-listed for footnotes and
  # code blocks, so a bare allow-list would still let a message cover the app
  # or lay an invisible link over it.
  test "markdown drops raw HTML a user typed, layout tags included" do
    assert_no_match(/<div/i, markdown('<div class="fixed inset-0 z-50 bg-black">covered</div>'))
    assert_no_match(/fixed inset-0/, markdown('<a href="https://evil.example" class="fixed inset-0">x</a>'))
    assert_no_match(/evil\.example/, markdown('<img src="https://evil.example/track.gif">'))
  end

  # A markdown link is built by the renderer itself, so a javascript: or data:
  # target survives filter_html and goes away only via the sanitize allow-list.
  test "markdown strips dangerous URL schemes from the links it generates" do
    assert_no_match(/javascript:/i, markdown("[click](javascript:alert(1))"))
    assert_no_match(/javascript:/i, markdown("![x](javascript:alert(1))"))
    assert_no_match(%r{data:text/html}i, markdown("[click](data:text/html;base64,PHNjcmlwdD4=)"))
    assert_no_match(/data:/i, markdown("![x](data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=)"))
  end

  test "markdown keeps ordinary image and link targets" do
    assert_match(%r{<img[^>]+src="https://example\.com/a\.png"}, markdown("![alt](https://example.com/a.png)"))
    assert_match(%r{href="https://example\.com"}, markdown("[x](https://example.com)"))
  end

  test "markdown still renders the formatting the chat relies on" do
    rendered = markdown("**bold** and `code` and [link](https://example.com)")

    assert_match(/<strong>bold<\/strong>/, rendered)
    assert_match(/<code>code<\/code>/, rendered)
    assert_match(%r{href="https://example\.com"}, rendered)
  end

  test "markdown renders images written as markdown" do
    assert_match(%r{<img[^>]+src="https://example\.com/a\.png"}, markdown("![alt](https://example.com/a.png)"))
  end

  test "markdown returns an empty string for blank input" do
    assert_equal "", markdown(nil)
    assert_equal "", markdown("")
  end
end
