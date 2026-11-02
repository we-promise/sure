require "test_helper"

class Account::LogoFetcher::AppStoreTest < ActiveSupport::TestCase
  ARTWORK = "https://is1-ssl.mzstatic.com/image/thumb/krungsri/512x512bb.jpg"

  setup do
    @store = Account::LogoFetcher::AppStore.new(domain: "krungsri.com", term: "Krungsri", countries: %w[th us], client: Account::LogoFetcher::Client.new)
    stub_request(:get, ARTWORK).to_return(status: 200, body: png(512))
  end

  test "returns icons of the institution's own apps only" do
    stub_search("th", [ app(1, "krungsri", "https://www.krungsri.com"), app(2, "UCHOOSE", "https://www.krungsriconsumer.com") ])
    stub_search("us", [ app(1, "krungsri", "https://www.krungsri.com"), app(3, "GO by Krungsri Auto", nil) ])

    icons = @store.icons

    assert_equal [ "appstore:1" ], icons.map(&:key)
    assert_equal [ 512, "appstore", "krungsri" ], [ icons.first.size, icons.first.source, icons.first.name ]
  end

  test "looks an app up by id and still checks its developer" do
    stub_request(:get, "https://itunes.apple.com/lookup?country=th&id=1").to_return(status: 200, body: { results: [ app(1, "krungsri", "https://www.krungsri.com") ] }.to_json)
    stub_request(:get, "https://itunes.apple.com/lookup?country=th&id=2").to_return(status: 200, body: { results: [ app(2, "Other", "https://other.com") ] }.to_json)
    stub_request(:get, "https://itunes.apple.com/lookup?country=us&id=2").to_return(status: 200, body: { results: [] }.to_json)
    stub_request(:get, "https://itunes.apple.com/lookup?country=us&id=1").to_return(status: 200, body: { results: [] }.to_json)

    assert_equal "appstore:1", @store.icon("1").key
    assert_nil @store.icon("2")
    assert_nil @store.icon("../1")
  end

  test "ignores artwork outside Apple's image hosts" do
    stub_search("th", [ app(1, "krungsri", "https://www.krungsri.com", artwork: "https://evil.example/icon.png") ])
    stub_search("us", [])

    assert_empty @store.icons
  end

  private
    def app(id, name, seller_url, artwork: ARTWORK)
      { trackId: id, trackName: name, sellerUrl: seller_url, artworkUrl512: artwork }
    end

    def stub_search(country, apps)
      stub_request(:get, "https://itunes.apple.com/search")
        .with(query: hash_including(country: country, term: "Krungsri"))
        .to_return(status: 200, body: { results: apps }.to_json)
    end

    def png(size)
      "\x89PNG\r\n\x1a\n".b + [ 13 ].pack("N") + "IHDR" + [ size, size ].pack("NN") + "\x08\x06\x00\x00\x00".b + "\x00" * 4 +
        [ 0 ].pack("N") + "IEND\xAEB`\x82".b
    end
end
