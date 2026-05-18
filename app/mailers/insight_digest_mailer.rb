class InsightDigestMailer < ApplicationMailer
  def weekly
    @user = params.fetch(:user)
    @insights = params.fetch(:insights)

    mail(
      to: @user.email,
      subject: t("insight_digest_mailer.weekly.subject", count: @insights.size)
    )
  end
end
