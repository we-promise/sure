# 2FA Login Flow Testing Guide

## Backend Confirmation
The backend 2FA implementation is confirmed working via tests:
- `test/controllers/api/v1/auth_controller_test.rb` lines 233-274
- When MFA is enabled, returns: `{"error": "Two-factor authentication required", "mfa_required": true}` with status 401
- When valid OTP provided, login succeeds with tokens

## Frontend Debug Steps

1. **Run the Flutter app with verbose logging:**
```bash
cd mobile
flutter run --verbose
```

2. **Attempt to login with a 2FA-enabled account**

3. **Check the console output for these debug messages:**
```
Login response status: 401
Login response body: {"error":"Two-factor authentication required","mfa_required":true}
Login result: {success: false, mfa_required: true, error: Two-factor authentication required}
MFA required! _mfaRequired set to: true
Login success: false, mfaRequired: true, _showOtpField: false
Showing OTP field...
```

## Expected Behavior After Fix

### Step 1: Initial Login
- User enters email and password
- Clicks "Sign In"
- Loading spinner appears

### Step 2: 2FA Required Response
- Backend responds with `mfa_required: true`
- **NO red error message** (it's a normal flow)
- **Blue info box appears** with message: "Two-factor authentication is enabled. Enter your code."
- **OTP input field appears**
- Loading spinner stops

### Step 3: OTP Entry
- User enters 6-digit code
- Clicks "Sign In" again
- Loading spinner appears

### Step 4: Success
- Backend validates OTP
- Returns access token
- App navigates to main screen

## Common Issues

### Issue 1: OTP field not showing
**Symptom:** Loading spinner appears then disappears, nothing happens
**Possible causes:**
- `authProvider.mfaRequired` not being set to true
- `setState` not being called
- Widget disposed before setState

### Issue 2: Red error message showing
**Symptom:** Red error box with "Two-factor authentication required"
**Fix:** Ensure `_errorMessage = null` when `mfa_required == true`

### Issue 3: App crashes
**Symptom:** "setState() called after dispose()"
**Fix:** Check `mounted` before calling `setState`

## Testing with curl

Test the backend API directly:

```bash
# Step 1: Try login without OTP (should get mfa_required)
curl -X POST http://localhost:3000/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{
    "email": "YOUR_EMAIL",
    "password": "YOUR_PASSWORD",
    "device": {
      "device_id": "test-device",
      "device_name": "Test Device",
      "device_type": "android",
      "os_version": "14",
      "app_version": "1.0.0"
    }
  }'

# Expected response:
# {"error":"Two-factor authentication required","mfa_required":true}

# Step 2: Generate OTP code (in Rails console)
# user = User.find_by(email: "YOUR_EMAIL")
# totp = ROTP::TOTP.new(user.otp_secret)
# puts totp.now

# Step 3: Login with OTP
curl -X POST http://localhost:3000/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{
    "email": "YOUR_EMAIL",
    "password": "YOUR_PASSWORD",
    "otp_code": "GENERATED_CODE",
    "device": {
      "device_id": "test-device",
      "device_name": "Test Device",
      "device_type": "android",
      "os_version": "14",
      "app_version": "1.0.0"
    }
  }'

# Expected response:
# {"access_token":"...", "refresh_token":"...", ...}
```
