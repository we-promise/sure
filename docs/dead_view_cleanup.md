# Dead view cleanup

This change removes a set of unused view partials that were no longer rendered anywhere in the application:

- `app/views/accounts/show/_activity.html.erb`
- `app/views/credit_cards/_overview.html.erb`
- `app/views/transfers/_account_links.html.erb`
- `app/views/layouts/shared/_page_header.html.erb`
- `app/views/shared/_app_version.html.erb`
- `app/views/shared/_logo.html.erb`
- `app/views/shared/_text_tooltip.erb`

Keeping only referenced templates helps simplify the view layer and avoid confusion during future refactors.
