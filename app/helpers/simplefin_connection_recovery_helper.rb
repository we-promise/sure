module SimplefinConnectionRecoveryHelper
  def simplefin_connection_request_title(connection_request)
    if %w[prepared claimed installed].include?(connection_request.state) && !connection_request.can_retry
      return t("simplefin_items.connection_recovery.titles.unavailable")
    end

    key = case connection_request.state
    when "uncertain" then "new_token_needed"
    when "claiming" then "in_progress"
    else "pending"
    end
    t("simplefin_items.connection_recovery.titles.#{key}")
  end

  def simplefin_connection_request_description(connection_request)
    if connection_request.state == "installed" && !connection_request.can_retry
      return t("simplefin_items.connection_recovery.descriptions.refresh_unavailable")
    end
    if %w[prepared claimed].include?(connection_request.state) && !connection_request.can_retry
      return t("simplefin_items.connection_recovery.descriptions.unavailable")
    end

    key = case connection_request.state
    when "prepared" then "prepared"
    when "claimed" then "claimed"
    when "installed" then "installed"
    when "claiming" then "claiming"
    when "uncertain" then "uncertain"
    else "unavailable"
    end
    t("simplefin_items.connection_recovery.descriptions.#{key}")
  end

  def simplefin_connection_request_variant(connection_request)
    connection_request.state == "uncertain" ? :warning : :info
  end
end
