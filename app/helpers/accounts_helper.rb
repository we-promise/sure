module AccountsHelper
  def summary_card(title:, &block)
    content = capture(&block)
    render "accounts/summary_card", title: title, content: content
  end

  def sync_path_for(account)
    if account.linked? && account.provider
      account.provider.sync_path
    else
      sync_account_path(account)
    end
  end
end
