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

  test "#styled_form_with keeps a field's help_text when the field has no label" do
    html = styled_form_with(url: "/", scope: :account) do |form|
      form.text_field :name, label: false, help_text: "Shown to everyone in the family"
    end

    fragment = Nokogiri::HTML.fragment(html)
    assert_equal "Shown to everyone in the family", fragment.at("p#account_name_help_text")&.text
    assert_equal "account_name_help_text", fragment.at("input[name='account[name]']")["aria-describedby"]
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
  # enough on its own: div, span, class and style stay allow-listed for
  # footnotes, code blocks and table alignment, so a bare allow-list would
  # still let a message cover the app or lay an invisible link over it.
  test "markdown drops raw HTML a user typed, layout tags included" do
    assert_no_match(/<div/i, markdown('<div class="fixed inset-0 z-50 bg-black">covered</div>'))
    assert_no_match(/position/i, markdown('<span style="position:fixed;inset:0">covered</span>'))
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

  test "markdown preserves underline formatting" do
    assert_includes markdown("This is _underlined_"), "<u>underlined</u>"
  end

  test "markdown preserves inline quote formatting" do
    assert_includes markdown('She said "hello"'), "<q>hello</q>"
  end

  test "markdown keeps the rest of the markup its extensions generate" do
    rendered = markdown(<<~MD)
      ==marked== ~~struck~~ x^2 note[^1]

      | left | right |
      |:-----|------:|
      | a    | b     |

      ```ruby
      x
      ```

      [^1]: footnote
    MD

    assert_includes rendered, "<mark>marked</mark>"
    assert_includes rendered, "<del>struck</del>"
    assert_includes rendered, "<sup>2</sup>"
    assert_match(%r{<sup id="fnref1"><a href="#fn1"[^>]*>1</a></sup>}, rendered)
    assert_match(%r{<div class="footnotes">.*<li id="fn1">}m, rendered)
    assert_match(%r{<th style="text-align:\s*left;?">left</th>}, rendered)
    assert_match(%r{<td style="text-align:\s*right;?">b</td>}, rendered)
    assert_includes rendered, '<code class="ruby">'
  end

  test "markdown renders images written as markdown" do
    assert_match(%r{<img[^>]+src="https://example\.com/a\.png"}, markdown("![alt](https://example.com/a.png)"))
  end

  test "markdown returns an empty string for blank input" do
    assert_equal "", markdown(nil)
    assert_equal "", markdown("")
  end

  test "#mask_last4 masks all but the last 4 characters" do
    assert_equal "•••7890", mask_last4("account-number-1234567890")
    assert_equal "•••2345", mask_last4("12345")
  end

  test "#mask_last4 returns nil for blank input" do
    assert_nil mask_last4(nil)
    assert_nil mask_last4("")
  end

  test "#mask_last4 handles values shorter than 4 characters" do
    assert_equal "•••12", mask_last4("12")
  end

  test "#format_money returns nil for nil input" do
    assert_nil format_money(nil)
  end

  test "#format_money defaults to the default currency" do
    assert_equal "$1,234.56", format_money(1234.56, locale: :en)
  end

  test "#format_money formats with an explicit currency" do
    assert_equal "1.234,56 €", format_money(1234.56, currency: "EUR", locale: :de)
    assert_equal "₹12,34,567.89", format_money(1234567.89, currency: "INR", locale: :en, amount_format: "indian")
  end

  test "#format_money passes precision through" do
    assert_equal "1.235 €", format_money(1234.56, currency: "EUR", locale: :de, precision: 0)
  end

  test "#format_money works with a Money instance" do
    assert_equal "1.234,56 €", format_money(Money.new(1234.56, :eur), locale: :de)
  end

  test "#format_money falls back to the raw code for an unknown currency" do
    assert_equal "1,234.56 XBT", format_money(1234.56, currency: "XBT", locale: :en)
  end

  # `group-open:` matches any open ancestor `.group`, so a chevron inside a
  # closed disclosure nested in an open one would show as open.
  test "#disclosure_chevron follows its own details element" do
    classes = nil
    singleton_class.send(:define_method, :lucide_icon) do |_key, **opts|
      classes = CGI.unescapeHTML(opts[:class].to_s)
      "<svg></svg>".html_safe
    end

    disclosure_chevron

    assert_includes classes, "[details[open]>summary_&]:rotate-90"
    assert_not_includes classes, "group-open:"
  ensure
    singleton_class.send(:remove_method, :lucide_icon) if singleton_class.method_defined?(:lucide_icon)
  end
end
