# AI Prompts settings – step-by-step test guide

Use this to manually test the AI Prompts UI (Endpoint & model + conditional OpenAI prompts).

**Prerequisites**
- App running: `bin/rails server -p 3001` (or your port)
- Admin user: e.g. `admin@test.com` / `password123` (or create one and set `role: admin`)

---

## Step 1: Log in

1. Open **http://localhost:3001** (or your port).
2. If redirected to `/sessions/new`, sign in with an **admin** user.
3. You should land on the dashboard (e.g. "Welcome back, …").

**Pass:** You see the app home/dashboard.

---

## Step 2: Open AI Prompts

1. Go to **Settings** (sidebar or profile menu).
2. Under **Advanced**, click **AI Prompts**.
   - Or go directly to: **http://localhost:3001/settings/ai_prompts**

**Pass:** Page title is "AI Prompts". You see:
- **Endpoint & model** section at the top (two fields + "Save changes").
- Below it, either the **OpenAI** card (with Main System Prompt, Transaction Categorizer, Merchant Detector) or the message that prompt customization is available when using an OpenAI-compatible model.

---

## Step 3: Endpoint & model section

1. In **Endpoint & model**:
   - **Custom API endpoint (optional)** – leave blank or enter e.g. `https://api.openai.com/v1`.
   - **Preferred AI model** – leave blank or enter e.g. `gpt-4.1` or `gpt-4o`.
2. Click **Save changes**.

**Pass:** Redirects back to the same page; flash message "AI prompts and model preferences saved." (No validation errors.)

**Optional:** Clear both fields and Save again. Pass: same success behavior.

---

## Step 4: Validation – endpoint without model

1. Set **Custom API endpoint** to `https://api.example.com/v1`.
2. Leave **Preferred AI model** empty.
3. Click **Save changes**.

**Pass:** Page re-renders with validation error; endpoint is not saved. After reload, endpoint field is empty.

---

## Step 5: View prompt (expand)

1. Ensure the **OpenAI** section is visible (default model is OpenAI-style, or you set a gpt-* model / custom endpoint).
2. In **Main System Prompt**, click **Prompt** (or the expand control).

**Pass:** Section expands and shows the current system prompt text (and model label e.g. `[gpt-4o]`).

3. Click **Prompt** again (or collapse).

**Pass:** Section collapses.

---

## Step 6: Edit Main System Prompt

1. Click **Edit prompt** next to Main System Prompt.
2. You should land on **Edit main system prompt** (`/settings/ai_prompts/edit_system_prompt`).

**Pass:** Page shows:
- Breadcrumb: Home > AI Prompts > Main system prompt
- "Main system prompt & intro" with two text areas (Custom main system prompt, Custom intro prompt).
- "Save changes" and "Back to AI Prompts".

3. Optionally change **Custom main system prompt** or **Custom intro prompt**, then click **Save changes**.

**Pass:** Redirect to `/settings/ai_prompts` with success message. Re-open "Edit prompt" and confirm your text is saved.

4. Click **Back to AI Prompts** from the edit page (without saving).

**Pass:** Returns to the AI Prompts overview.

---

## Step 7: Transaction Categorizer & Merchant Detector (read-only / coming soon)

1. On the AI Prompts overview, find **Transaction Categorizer** and **Merchant Detector**.
2. Click **Prompt** (or "Prompt instructions" for Merchant) to expand.

**Pass:** Prompt text is visible (read-only).

3. Check the edit action.

**Pass:** Shows "Edit prompt (coming soon!)" (no link to edit).

---

## Step 8: Conditional OpenAI section – hide prompts

1. In **Endpoint & model**, set **Preferred AI model** to a non–OpenAI-style value, e.g. `qwen3` or `some-other-model`.
2. Click **Save changes**.

**Pass:** The **OpenAI** card (Main System Prompt, Transaction Categorizer, Merchant Detector) disappears. You see the message: "Prompt customization is available when using an OpenAI-compatible model. Set a compatible model (e.g. gpt-4) or custom endpoint above to see prompts."

3. Set **Preferred AI model** back to e.g. `gpt-4o` (or clear it to use app default) and Save.

**Pass:** The OpenAI section appears again.

---

## Step 9: Non-admin cannot access

1. Log out (or use an incognito window).
2. Log in as a **non-admin** user (e.g. `role: member`).
3. Go to **http://localhost:3001/settings/ai_prompts**.

**Pass:** Redirect to home with alert "You are not authorized to change AI prompts for this household."

---

## Quick checklist

- [ ] Step 1: Log in as admin
- [ ] Step 2: Open AI Prompts
- [ ] Step 3: Save endpoint & model (valid)
- [ ] Step 4: Validation when endpoint set without model
- [ ] Step 5: Expand/collapse "Prompt" for Main System Prompt
- [ ] Step 6: Edit prompt page + save + back link
- [ ] Step 7: Transaction Categorizer / Merchant Detector view + "coming soon"
- [ ] Step 8: Non-OpenAI model hides OpenAI section; switching back shows it
- [ ] Step 9: Non-admin is redirected with not_authorized
