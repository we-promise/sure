# Tells a user what became of an order email they forwarded to the order mailbox.
class PurchaseMailer < ApplicationMailer
  helper_method :purchase_total, :purchase_transaction_entry

  def processed
    purchase_mail(:processed)
  end

  def matched
    purchase_mail(:matched)
  end

  def unmatched
    purchase_mail(:unmatched)
  end

  def needs_matching
    purchase_mail(:needs_matching)
  end

  def rejected
    @reason = params[:purchase].review_reasons.reverse.find { _1["reason"].in?(%w[duplicate not_an_order]) }
    purchase_mail(:rejected)
  end

  def failed
    purchase_mail(:failed)
  end

  def preview_required
    @user = params[:user]
    I18n.with_locale(locale_for(@user)) do
      @preferences_url = settings_preferences_url
      mail(to: @user.email, subject: t(".subject", product_name:))
    end
  end

  private
    def purchase_mail(action)
      @purchase = params[:purchase]
      @user = @purchase.user
      I18n.with_locale(locale_for(@user)) do
        mail(to: @user.email, subject: t("purchase_mailer.#{action}.subject", merchant: merchant_name, total: purchase_total))
      end
    end

    def locale_for(user)
      user.locale.presence || I18n.default_locale
    end

    def merchant_name
      @purchase.merchant.presence || t("purchase_mailer.unknown_merchant")
    end

    def purchase_total
      @purchase.amount_text(@purchase.total)
    end

    # Only while the owner can still see its account: mail goes out later, and access may have
    # been taken away since the link.
    def purchase_transaction_entry
      entry = @purchase.linked_transaction&.entry
      entry if entry && Account.accessible_by(@purchase.user).exists?(id: entry.account_id)
    end
end
