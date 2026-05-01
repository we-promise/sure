> [!NOTE]
> Sure supports multiple Enable Banking connections for the same family. If you need to connect more than one bank, or the same bank with a different login, repeat the connection flow for each one.

> [!NOTE]
> Enable Banking sandbox apps do not return real transaction data. Use a production Enable Banking app when you want actual syncs.

> [!NOTE]
> During the initial bank authorization flow, your Sure instance must be reachable from the public internet over HTTPS so Enable Banking can redirect back to it. After the first connection is established, you can usually remove the temporary tunnel or public exposure.

# Setting Up Enable Banking

## 1. Create your Enable Banking application

1. Sign in to your [Enable Banking developer account](https://enablebanking.com/).
2. Create an application for your self-hosted Sure instance.
3. Copy the following values from Enable Banking:
   - **Application ID**
   - **Client Certificate** including the private key
4. Add your Sure callback URL to the application's allowed redirect URLs:
   - `https://YOUR-SURE-DOMAIN/enable_banking/callback`

## 2. Configure Enable Banking in Sure

1. In Sure, go to **Settings -> Providers -> Enable Banking**.
2. Select the correct **Country Code** for the bank you want to connect.
3. Paste your **Application ID**.
4. Paste your **Client Certificate** with the private key included.
5. Click **Save Configuration**.

## 3. Connect your first bank

1. In the Enable Banking section, click **Connect Bank**.
2. Pick your bank.
3. Complete the bank's authorization flow.
4. After you return to Sure, wait for the sync to finish and link any imported accounts if prompted.

## 4. Connect additional banks or additional logins

If you want to connect multiple different Enable Banking accounts, click **Add Connection** after your first connection is working.

Use **Add Connection** when you want to:

- connect a second bank
- connect the same bank again with a different online banking login
- keep separate Enable Banking connections for different institutions

Each connection is stored separately in Sure, so you can sync, reconnect, or remove them independently.

## 5. Updating credentials

Once you have active Enable Banking connections, Sure locks the shared credential fields to avoid breaking existing connections. If you need to change the Application ID or Client Certificate, remove the existing connections first, then save the new credentials and reconnect.

## Troubleshooting

### I connected my bank but no transactions appeared

Check these first:

1. You are using a **production** Enable Banking app, not a sandbox app.
2. The bank connection completed successfully and shows as connected in **Settings -> Providers**.
3. The imported account was linked to the correct Sure account type.

### Redirect not allowed

Make sure this callback URL is registered in your Enable Banking application settings:

- `https://YOUR-SURE-DOMAIN/enable_banking/callback`

### I need to reconnect a bank

If a bank session expires, use the **Reconnect** button next to that connection in **Settings -> Providers -> Enable Banking**.
