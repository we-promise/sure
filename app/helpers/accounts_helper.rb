module AccountsHelper
  def summary_card(title:, &block)
    content = capture(&block)
    render "accounts/summary_card", title: title, content: content
  end

  def sync_path_for(account)
    if account.plaid_account_id.present?
      sync_plaid_item_path(account.plaid_account.plaid_item)
    elsif account.simplefin_account_id.present?
      sync_simplefin_item_path(account.simplefin_account.simplefin_item)
    else
      sync_account_path(account)
    end
  end
end
