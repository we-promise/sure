# Offline Features Documentation

## Overview

The Sure mobile app implements a comprehensive offline-first architecture that allows users to continue using the app even when they don't have an internet connection. All transactions created offline are automatically synced to the server when the connection is restored.

## Key Features

### 1. Offline Data Storage

- **Local SQLite Database**: All transaction and account data is stored locally using SQLite
- **Automatic Caching**: Server data is automatically cached for offline access
- **Persistent Storage**: Data persists across app restarts

### 2. Offline Transaction Management

- **Create Transactions Offline**: Users can create new transactions even without internet
- **View Cached Data**: Access previously synced transactions and accounts offline
- **Pending Sync Indicator**: Transactions created offline are marked as "pending" until synced

### 3. Automatic Synchronization

- **Network Detection**: App automatically detects when network connectivity is restored
- **Background Sync**: Pending transactions are automatically uploaded when online
- **Server Data Download**: Latest server data is downloaded and cached locally
- **Conflict Resolution**: Server data takes precedence during sync

### 4. Visual Indicators

- **Connectivity Banner**: Shows current connection status and pending transaction count
- **Sync Status Badges**: Individual transactions show their sync status (pending/failed/synced)
- **Manual Sync Button**: Users can trigger sync manually when online

## Architecture

### Data Flow

```
┌─────────────────┐
│  User Interface │
└────────┬────────┘
         │
         ▼
┌─────────────────────────┐
│ TransactionsProvider    │
│ (State Management)      │
└────────┬───────┬────────┘
         │       │
         │       ▼
         │  ┌──────────────────────┐
         │  │ ConnectivityService  │
         │  │ (Network Detection)  │
         │  └──────────────────────┘
         │
         ▼
┌─────────────────────────┐
│ OfflineStorageService   │
│ (Local SQLite DB)       │
└─────────────────────────┘
         ▲
         │
         ▼
┌─────────────────────────┐
│ SyncService             │
│ (Server Sync Logic)     │
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│ TransactionsService     │
│ (HTTP API Client)       │
└─────────────────────────┘
```

### Database Schema

#### Transactions Table
```sql
CREATE TABLE transactions (
  local_id TEXT PRIMARY KEY,      -- UUID generated locally
  server_id TEXT,                  -- Server ID after sync
  account_id TEXT NOT NULL,
  name TEXT NOT NULL,
  date TEXT NOT NULL,
  amount TEXT NOT NULL,
  currency TEXT NOT NULL,
  nature TEXT NOT NULL,
  notes TEXT,
  sync_status TEXT NOT NULL,       -- 'synced', 'pending', 'failed'
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
)
```

#### Accounts Table (Cache)
```sql
CREATE TABLE accounts (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  balance TEXT NOT NULL,
  currency TEXT NOT NULL,
  classification TEXT,
  account_type TEXT NOT NULL,
  synced_at TEXT NOT NULL
)
```

## Components

### Services

#### 1. ConnectivityService (`lib/services/connectivity_service.dart`)
- Monitors network connectivity status
- Provides real-time connectivity updates
- Uses `connectivity_plus` package

#### 2. DatabaseHelper (`lib/services/database_helper.dart`)
- Manages SQLite database operations
- Handles table creation and migrations
- Provides CRUD operations for local data

#### 3. OfflineStorageService (`lib/services/offline_storage_service.dart`)
- High-level API for offline data management
- Converts between app models and database records
- Manages transaction sync status

#### 4. SyncService (`lib/services/sync_service.dart`)
- Coordinates data synchronization with server
- Uploads pending transactions
- Downloads and caches server data
- Handles sync errors and retries

### Models

#### OfflineTransaction (`lib/models/offline_transaction.dart`)
```dart
class OfflineTransaction extends Transaction {
  final String localId;           // Local UUID
  final SyncStatus syncStatus;     // Sync state
  final DateTime createdAt;        // Local creation time
  final DateTime updatedAt;        // Last update time
}

enum SyncStatus {
  synced,    // Successfully synced with server
  pending,   // Waiting to be synced
  failed,    // Last sync attempt failed
}
```

### UI Components

#### 1. ConnectivityBanner (`lib/widgets/connectivity_banner.dart`)
- Displays at top of screen when offline or has pending transactions
- Shows "Sync Now" button when online with pending items
- Auto-hides when online and all synced

#### 2. SyncStatusBadge (`lib/widgets/sync_status_badge.dart`)
- Shows sync status for individual transactions
- Compact mode for list items
- Full mode for transaction details

## Usage Examples

### Creating a Transaction Offline

```dart
final transactionsProvider = Provider.of<TransactionsProvider>(context, listen: false);
final authProvider = Provider.of<AuthProvider>(context, listen: false);

await transactionsProvider.createTransaction(
  accessToken: authProvider.tokens!.accessToken,
  accountId: account.id,
  name: 'Coffee',
  date: '2024-01-15',
  amount: '5.50',
  currency: 'USD',
  nature: 'expense',
  notes: 'Morning coffee',
);

// Transaction is saved locally with status 'pending'
// Will auto-sync when connection is restored
```

### Manual Sync

```dart
final transactionsProvider = Provider.of<TransactionsProvider>(context, listen: false);
final authProvider = Provider.of<AuthProvider>(context, listen: false);

await transactionsProvider.syncTransactions(
  accessToken: authProvider.tokens!.accessToken,
);
```

### Checking Connectivity Status

```dart
final connectivityService = Provider.of<ConnectivityService>(context);

if (connectivityService.isOnline) {
  // App is online
} else {
  // App is offline
}
```

### Checking Pending Transactions

```dart
final transactionsProvider = Provider.of<TransactionsProvider>(context);

if (transactionsProvider.hasPendingTransactions) {
  print('Pending count: ${transactionsProvider.pendingCount}');
}
```

## Sync Behavior

### When Creating a Transaction

1. **Online**:
   - Attempts to create on server immediately
   - On success: Saves to local DB with status 'synced'
   - On failure: Saves to local DB with status 'pending'

2. **Offline**:
   - Saves to local DB with status 'pending'
   - Shows success to user (transaction is saved locally)
   - Will sync automatically when connection restored

### When Loading Transactions

1. **Always** loads from local SQLite first (instant display)
2. **If online** and local is empty, syncs from server
3. **If force refresh**, syncs from server and updates local cache

### Automatic Sync

The app automatically syncs in these scenarios:
- App starts with internet connection
- Network connection is restored after being offline
- User manually triggers sync via "Sync Now" button
- User pulls to refresh on dashboard or transaction list

### Sync Process

1. **Upload Phase**:
   - Gets all pending transactions from local DB
   - Uploads each to server sequentially
   - Updates local records with server IDs on success
   - Marks as 'failed' if upload fails

2. **Download Phase**:
   - Fetches all transactions from server
   - Updates local cache with server data
   - Server data takes precedence over local changes

3. **Account Sync**:
   - Updates local account cache with latest balances
   - Ensures account dropdown has current data

## Error Handling

### Network Errors
- Transactions remain marked as 'pending'
- User can retry sync manually
- Visual indicator shows sync failure

### Sync Conflicts
- Server data always takes precedence
- Local pending transactions are uploaded first
- Then server data is downloaded and cached

### Database Errors
- Errors are logged and reported to user
- App continues to function with potentially stale data
- User can force refresh to retry

## Testing Offline Functionality

### Simulating Offline Mode

1. **Android Emulator**:
   - Swipe down notification panel
   - Toggle Airplane Mode

2. **iOS Simulator**:
   - Settings → Airplane Mode → ON

3. **Physical Device**:
   - Enable Airplane Mode in device settings

### Test Scenarios

1. **Create Transaction Offline**:
   - Turn on airplane mode
   - Create a new transaction
   - Verify it appears in the list with "pending" badge
   - Turn off airplane mode
   - Verify automatic sync occurs

2. **View Cached Data**:
   - Use app while online
   - Turn on airplane mode
   - Verify all previously viewed data is still accessible

3. **Manual Sync**:
   - Create transactions offline
   - Turn off airplane mode
   - Tap "Sync Now" button
   - Verify transactions sync successfully

## Performance Considerations

- **Database Size**: SQLite can handle millions of records efficiently
- **Sync Batching**: Pending transactions are uploaded sequentially to avoid overwhelming the server
- **Cache Invalidation**: Account cache is refreshed on each sync to ensure accurate balances
- **Memory Usage**: Only active transactions are kept in memory; database queries are paginated

## Future Enhancements

Potential improvements for future versions:

1. **Conflict Resolution UI**: Allow users to choose which version to keep when conflicts occur
2. **Selective Sync**: Sync only specific accounts or date ranges
3. **Background Sync**: Use platform background tasks for periodic syncing
4. **Offline Editing**: Support editing transactions offline
5. **Offline Deletion**: Support deleting transactions offline with sync
6. **Export Offline Data**: Export local database for backup
7. **Data Compression**: Compress large sync payloads for better performance

## Troubleshooting

### Transactions Not Syncing

1. Check internet connection
2. Verify you're logged in (tokens are valid)
3. Check sync status in app (ConnectivityBanner)
4. Try manual sync via "Sync Now" button
5. Check server logs for API errors

### Database Issues

1. Clear app data (will lose offline transactions)
2. Reinstall app
3. Contact support if issue persists

### Performance Issues

1. Check device storage (database needs space)
2. Consider clearing old synced transactions
3. Reduce number of accounts if possible
