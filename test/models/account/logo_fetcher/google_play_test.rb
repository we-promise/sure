require "test_helper"

class Account::LogoFetcher::GooglePlayTest < ActiveSupport::TestCase
  ICON = "https://play-lh.googleusercontent.com/kma-icon"

  setup do
    @store = Account::LogoFetcher::GooglePlay.new(domain: "krungsri.com", term: "Krungsri", country: "th", client: Account::LogoFetcher::Client.new)
    stub_request(:get, "#{ICON}=s512").to_return(status: 200, body: png(512))
  end

  test "returns icons of apps whose developer website is the institution" do
    stub_request(:get, "https://play.google.com/store/search")
      .with(query: hash_including(q: "Krungsri", gl: "th"))
      .to_return(status: 200, body: %(<a href="/store/apps/details?id=com.krungsri.kma">x</a><a href="/store/apps/details?id=com.other.app">y</a>))
    stub_app("com.krungsri.kma", "https://www.krungsri.com/", "krungsri &amp; you - Apps on Google Play")
    stub_app("com.other.app", "https://other.example/", "Other - Apps on Google Play")

    icons = @store.icons

    assert_equal [ "googleplay:com.krungsri.kma" ], icons.map(&:key)
    assert_equal [ 512, "googleplay", "krungsri & you" ], [ icons.first.size, icons.first.source, icons.first.name ]
  end

  test "rejects malformed packages and icons outside Google's image host" do
    assert_nil @store.icon("../../evil")

    stub_app("com.krungsri.kma", "https://www.krungsri.com/", "krungsri", icon: "https://evil.example/icon")
    assert_nil @store.icon("com.krungsri.kma")
  end

  private
    def stub_app(package, developer_url, title, icon: ICON)
      page = %(<meta property="og:title" content="#{title}"><meta property="og:image" content="#{icon}=s0-br30">) +
             %(<meta name="appstore:developer_url" content="#{developer_url}">)
      stub_request(:get, "https://play.google.com/store/apps/details")
        .with(query: hash_including(id: package))
        .to_return(status: 200, body: page)
    end

    def png(size)
      "\x89PNG\r\n\x1a\n".b + [ 13 ].pack("N") + "IHDR" + [ size, size ].pack("NN") + "\x08\x06\x00\x00\x00".b + "\x00" * 4 +
        [ 0 ].pack("N") + "IEND\xAEB`\x82".b
    end
end
