# Hotwire Native Prototype Plan

## Overview
- Evaluate how the existing PWA experience can be wrapped inside Hotwire Native shells for iOS and Android clients.
- Deliver a focused prototype branch that proves the Rails + Hotwire stack can expose the Turbo-powered flows required by the wrapper applications without disrupting the web PWA.
- Produce clear implementation guidance so subsequent work streams can execute quickly.

## Goals
1. Validate that our current Turbo stream usage maps cleanly onto the Hotwire Native navigation model.
2. Document the configuration required in Rails to support Turbo Native (custom user agent detection, native-specific navigation fallbacks, authentication flows).
3. Ship a thin spike demonstrating native navigation + authentication for a single high-value flow (account overview) while preserving PWA behavior.

## Branch Strategy
- Create branch: `feature/hotwire-native-prototype` off the latest `main` once approved.
- Keep the branch short-lived and focused on enabling Hotwire Native wrappers; avoid unrelated refactors.
- Land planning artifacts (this doc + tooling updates) on `work`, then branch from `main` for implementation work.

## Research Checklist
- [x] Review the official [Hotwire Native announcement](https://dev.37signals.com/announcing-hotwire-native/) for required gem versions and navigation primitives.
- [x] Audit existing Turbo usage (frames, streams) for compatibility with the native navigation stack.
- [x] Confirm PWA assets (manifest, service worker) do not conflict with Turbo Native user agents.
- [x] Identify areas needing native-only navigation or modal handling (e.g., file uploads, OAuth redirects).

## Prototype Scope
1. **Authentication**
   - Ensure Turbo Native requests receive the same CSRF/session handling as web requests.
   - Add native-only sign-out redirect handling if necessary.
2. **Navigation shell**
   - Implement native navigation menus using Turbo Native visit proposals.
   - Verify deep links from push notifications or emails open correctly in native wrapper.
3. **Account overview flow**
   - Confirm account listing, detail, and transactions operate within Turbo frames on native clients.
   - Identify any Stimulus controllers that require native-specific tweaks (file uploads, clipboard, etc.).

## Rails Changes (Prototype)
- Add middleware or request variant detection (`request.user_agent`) to differentiate Turbo Native clients.
- Provide native-specific layouts or partials when `turbo_native?` is true.
- Evaluate if any redirect logic needs `turbo_stream` fallbacks for native navigation.

## Prototype Implementation Summary (Branch: `feature/hotwire-native-prototype`)
- **Turbo Native request detection**: Introduced a controller concern that inspects user agents and bridge headers, setting the `:turbo_native` variant for layouts and views. Helpers expose `turbo_native_app?` for conditional rendering.
- **Native-first layout**: Added `application.html+turbo_native.erb`, a slim layout that shares HTML chrome with the web experience while exporting navigation metadata and bridge hooks for the iOS/Android wrappers.
- **Navigation manifest**: Centralized navigation items in `ApplicationHelper` and expose a serialized payload used by both the layout variant and the Stimulus bridge so wrappers can render native tab bars consistently.
- **Bridge controller**: Added a `turbo_native_bridge` Stimulus controller that notifies native shells about navigation updates, listens for native visit requests, and dispatches lifecycle events for deeper integrations.
- **Authentication redirect**: Sign-out responses now set `Turbo-Visit-Control: reload` when handled by a native wrapper to force a clean session reset without breaking the PWA.

## Native Wrapper Considerations
- Outline minimal iOS and Android wrapper requirements (Turbo Native libraries, authentication handshake, build tooling).
- Document environment variables or configuration the mobile shells must provide (base URL, client secrets, etc.).
- Plan to share session cookies between webview visits; confirm domain and TLS prerequisites.

## Testing & QA Strategy
- Manual QA matrix covering web (PWA) and Turbo Native wrappers for the account overview flow.
- Automation exploration: evaluate if we can reuse PWA system tests with custom user agent to simulate Turbo Native.
- Define roll-back plan if native wrapper introduces regressions to PWA.

## Open Questions
- Do we require offline caching beyond the existing service worker when running inside the native webview?
- How will biometric authentication hooks integrate with the current session management?
- What analytics adjustments are needed to differentiate native wrapper traffic?

## Next Steps
1. Socialize this plan with stakeholders and collect feedback.
2. Once approved, cut `feature/hotwire-native-prototype` from `main`.
3. Execute the prototype tasks, tracking progress in the branch README or project board. **(In progress on `feature/hotwire-native-prototype`.)**
4. Iterate on documentation based on findings before merging back into `main`. **Document updates captured above; continue refining with mobile-team feedback.**
