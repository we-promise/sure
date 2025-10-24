# Configuring OpenID Connect with Google

This guide shows how to enable OpenID Connect (OIDC) logins for Sure using Google as the identity provider.

## 1. Create a Google Cloud project

1. Visit [https://console.cloud.google.com](https://console.cloud.google.com) and sign in.
2. Create a new project or select an existing one.

## 2. Configure the OAuth consent screen

1. Navigate to **APIs & Services > OAuth consent screen**.
2. Choose **External** and follow the prompts to configure the consent screen.
3. Add your Google account as a test user.

## 3. Create OAuth client credentials

1. Go to **APIs & Services > Credentials** and click **Create Credentials > OAuth client ID**.
2. Select **Web application** as the application type.
3. Add an authorized redirect URI. For local development use:
   ```
   http://localhost:3000/auth/openid_connect/callback
   ```
   Replace with your domain for production, e.g.:
   ```
   https://yourdomain.com/auth/openid_connect/callback
   ```
4. After creating the credentials, copy the **Client ID** and **Client Secret**.

## 4. Configure Sure

Set the following environment variables in your deployment (e.g. `.env`, `docker-compose`, or hosting platform):

```bash
OIDC_ISSUER="https://accounts.google.com"
OIDC_CLIENT_ID="your-google-client-id"
OIDC_CLIENT_SECRET="your-google-client-secret"
OIDC_REDIRECT_URI="https://yourdomain.com/auth/openid_connect/callback"
```

Restart the application after saving the variables.

The user can now sign in from the login page using the **Sign in with OpenID Connect** link. Google must report the user's email as verified and it must match the email on the account.
