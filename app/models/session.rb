class Session < ApplicationRecord
  belongs_to :user
  belongs_to :active_impersonator_session,
    -> { where(status: :in_progress) },
    class_name: "ImpersonationSession",
    optional: true

  before_create :assign_request_metadata
  after_create_commit :notify_unusual_login_country

  def get_preferred_tab(tab_key)
    data.dig("tab_preferences", tab_key)
  end

  def set_preferred_tab(tab_key, tab_value)
    data["tab_preferences"] ||= {}
    data["tab_preferences"][tab_key] = tab_value
    save!
  end

  def country_name
    ISO3166::Country[country_code]&.name
  end

  private
    def assign_request_metadata
      self.user_agent = Current.user_agent
      self.ip_address = Current.ip_address
      self.country_code = IpCountryResolver.call(Current.ip_address)
    end

    def notify_unusual_login_country
      return if country_code.blank?

      first_three_sessions = user.sessions.where.not(country_code: nil).order(:created_at).limit(3)
      return if first_three_sessions.size < 3
      return if first_three_sessions.any? { |session| session.id == id }

      usual_country_code = first_three_sessions.map(&:country_code).tally.max_by { |_, count| count }&.first
      return if usual_country_code.blank? || usual_country_code == country_code

      SecurityMailer.with(user: user, session: self, usual_country_code: usual_country_code).unusual_login.deliver_later
    end
end
