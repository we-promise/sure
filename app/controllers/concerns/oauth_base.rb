module OauthBase
  extend ActiveSupport::Concern

  private
    def configured_base_url
      (ENV["APP_URL"].presence || request.base_url).chomp("/")
    end
end
