module CashVault
  class AuthController < BaseController
    def new
    end

    def create
      session.delete(:cash_vault_unlocked)

      if Current.true_user&.authenticate(params[:password].to_s)
        session[:cash_vault_unlocked] = true
        redirect_to cash_vault_transactions_path
      else
        flash.now[:alert] = t(".invalid_password")
        render :new, status: :unprocessable_entity
      end
    end
  end
end
