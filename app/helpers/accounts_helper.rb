module AccountsHelper
  ACTIVITY_HIGHLIGHT_MARKUP = '<span class="text-warning/80 font-medium underline decoration-warning/60 underline-offset-2">\1</span>'.freeze

  def summary_card(title:, &block)
    content = capture(&block)
    render "accounts/summary_card", title: title, content: content
  end

  def sync_path_for(account)
    # Always use the account sync path, which handles syncing all providers
    sync_account_path(account)
  end

  def highlight_activity_entry_name(name, query = params.dig(:q, :search))
    search = query.to_s.strip
    return name if search.blank?

    escaped_name = ERB::Util.html_escape(name.to_s)
    highlight(escaped_name, search, highlighter: ACTIVITY_HIGHLIGHT_MARKUP, sanitize: false)
  end
end
