require "capybara/selenium/driver"

# Capybara 3.40 ends each Chrome session reset with the DevTools command
# Storage.clearDataForOrigin for the origin "*". Chrome 158 rejects "*" as an
# invalid URL, and the error fails every system test in its teardown. When
# that happens, clear the same data another way: cookies for every site, and
# the other storage types for the origins the tests run on. Browsers that
# still accept "*" never reach the fallback.
module CapybaraChromeResetFallback
  private
    def execute_cdp(cmd, params = {})
      super
    rescue Selenium::WebDriver::Error::InvalidArgumentError
      raise unless cmd == "Storage.clearDataForOrigin" && params[:origin] == "*"

      types = params[:storageTypes].to_s.split(",")
      super("Network.clearBrowserCookies") if types.delete("cookies")
      return if types.empty?

      app_origins.each { |origin| super(cmd, origin: origin, storageTypes: types.join(",")) }
    end

    def app_origins
      [ Capybara.app_host, Capybara.current_session.server&.base_url ].compact.map { |url| URI(url).origin }.uniq
    end
end

Capybara::Selenium::Driver::ChromeDriver.prepend(CapybaraChromeResetFallback)
