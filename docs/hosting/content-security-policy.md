# Content Security Policy

Sure sends a Content-Security-Policy (CSP) header with every page. The browser then runs only the scripts that Sure itself renders, so injected markup cannot run JavaScript. The policy lives in `config/initializers/content_security_policy.rb`.

## What it allows out of the box

- Scripts, styles, fonts and connections from Sure's own origin.
- Plaid Link, so bank connections keep working.
- PostHog, but only when analytics or the feedback survey are turned on. If `POSTHOG_HOST` contains a path (for example a reverse proxy at `https://example.com/ingest`), only its origin is allowed, so every path on that host works.
- Images from any `https:` URL. If you use `generic_s3` storage with a plain `http://` `GENERIC_S3_ENDPOINT` (for example a local MinIO), that endpoint's origin is allowed too. Without `GENERIC_S3_FORCE_PATH_STYLE=true` the bucket subdomain of that endpoint is allowed as well.

## When something breaks

Some proxies and CDNs inject their own scripts into every page. Sure's policy blocks those scripts, because they do not carry its nonce. Known examples are Cloudflare Web Analytics, Rocket Loader and the email obfuscation in Scrape Shield. Turn those features off for your Sure host if you can.

If you cannot, or you need time to find out what is blocked, set:

```bash
CSP_REPORT_ONLY=true
```

Sure then sends the same policy as `Content-Security-Policy-Report-Only`. The browser blocks nothing and only lists each violation in its developer console. Restart the app after changing the variable. Use this as a temporary escape hatch: while it is set, the policy no longer protects against injected scripts.

## Permissions Policy

Sure also disables browser features it never uses (camera, microphone, geolocation, USB, payment and fullscreen). It sends this list both as `Permissions-Policy` and as the older `Feature-Policy` header. The list lives in `config/initializers/permissions_policy.rb`.
