class SessionsController < ApplicationController
  before_action :set_session, only: :destroy
  skip_authentication only: %i[new create openid_connect failure]

  layout "auth"

  def new
  end

  def create
    if user = User.authenticate_by(email: params[:email], password: params[:password])
      if user.otp_required?
        session[:mfa_user_id] = user.id
        redirect_to verify_mfa_path
      else
        @session = create_session_for(user)
        redirect_to root_path
      end
    else
      flash.now[:alert] = t(".invalid_credentials")
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    @session.destroy
    redirect_to new_session_path, notice: t(".logout_successful")
  end

  def openid_connect
    auth = request.env["omniauth.auth"]
    flow = request.env.fetch("omniauth.params", {})&.[]("flow")

    if auth.blank?
      return redirect_to(flow == "signup" ? new_registration_path : new_session_path, alert: t(flow == "signup" ? ".signup_failed" : ".failed"))
    end

    if (user = User.find_by(email: auth.info.email))
      @session = create_session_for(user)
      redirect_to root_path
    elsif flow == "signup"
      user = create_user_from_openid(auth)

      if user&.persisted?
        @session = create_session_for(user)
        redirect_to preferences_onboarding_path
      else
        redirect_to new_registration_path, alert: t(".signup_failed")
      end
    else
      redirect_to new_session_path, alert: t(".failed")
    end
  end

  def failure
    redirect_to new_session_path, alert: t(".failed")
  end

  private
    def set_session
      @session = Current.user.sessions.find(params[:id])
    end

    def create_user_from_openid(auth)
      info = auth.info
      email = info.email.to_s.strip.downcase
      return nil if email.blank?

      first_name, last_name = extract_name_parts(info)
      fallback_name = fallback_name_from_email(email) || "User"
      first_name ||= fallback_name
      last_name ||= fallback_name
      family_name = determine_family_name(last_name, first_name, email)

      ActiveRecord::Base.transaction do
        family = Family.create!(
          name: family_name,
          locale: "en",
          currency: "USD",
          country: "US",
          date_format: "%Y-%m-%d"
        )

        family.users.create!(
          email: email,
          password: SecureRandom.base58(24),
          role: :admin,
          first_name: first_name,
          last_name: last_name
        )
      end
    rescue ActiveRecord::RecordInvalid => error
      Rails.logger.error("OpenID Connect sign up failed: #{error.message}")
      nil
    end

    def extract_name_parts(info)
      first = info.first_name.to_s.strip.presence
      last = info.last_name.to_s.strip.presence

      if first.blank? || last.blank?
        name_parts = info.name.to_s.strip.split
        first ||= name_parts.first
        last ||= name_parts.last if name_parts.size > 1
      end

      [ first, last ]
    end

    def determine_family_name(last_name, first_name, email)
      last_name.presence || first_name.presence || fallback_name_from_email(email) || "Household"
    end

    def fallback_name_from_email(email)
      email.to_s.split("@").first.to_s.gsub(/[._-]+/, " ").squeeze(" ").strip.titleize.presence
    end
end
