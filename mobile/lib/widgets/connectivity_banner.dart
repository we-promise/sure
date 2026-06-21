import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/connectivity_service.dart';
import '../providers/transactions_provider.dart';
import '../providers/auth_provider.dart';
import '../l10n/app_localizations.dart';

class ConnectivityBanner extends StatefulWidget {
  const ConnectivityBanner({super.key});

  @override
  State<ConnectivityBanner> createState() => _ConnectivityBannerState();
}

class _ConnectivityBannerState extends State<ConnectivityBanner> {
  bool _isSyncing = false;

  Future<void> _handleSync(BuildContext context, String? accessToken, TransactionsProvider transactionsProvider) async {
    // Capture context-derived objects before the async gap so we never touch
    // `context` after an await.
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (accessToken == null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(l.connectivitySignInToSync),
          backgroundColor: Colors.orange,
        ),
      );
      if (mounted) {
        setState(() {
          _isSyncing = false;
        });
      }
      return;
    }

    try {
      await transactionsProvider.syncTransactions(accessToken: accessToken);

      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(l.connectivitySyncSuccess),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(l.connectivitySyncFailed),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSyncing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<ConnectivityService, TransactionsProvider>(
      builder: (context, connectivityService, transactionsProvider, _) {
        final l = AppLocalizations.of(context);
        final isOffline = connectivityService.isOffline;
        final hasPending = transactionsProvider.hasPendingTransactions;
        final pendingCount = transactionsProvider.pendingCount;

        if (!isOffline && !hasPending) {
          return const SizedBox.shrink();
        }

        return Material(
          color: isOffline ? Colors.orange.shade100 : Colors.blue.shade100,
          elevation: 2,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(
                  isOffline ? Icons.cloud_off : Icons.sync,
                  color: isOffline ? Colors.orange.shade900 : Colors.blue.shade900,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    isOffline
                        ? l.connectivityOffline
                        : l.connectivityPendingSync(pendingCount),
                    style: TextStyle(
                      color: isOffline ? Colors.orange.shade900 : Colors.blue.shade900,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (!isOffline && hasPending)
                  Consumer<AuthProvider>(
                    builder: (context, authProvider, _) {
                      return TextButton(
                        onPressed: _isSyncing
                            ? null
                            : () async {
                                setState(() {
                                  _isSyncing = true;
                                });

                                String? accessToken;
                                try {
                                  accessToken = await authProvider.getValidAccessToken();
                                } catch (e) {
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(l.connectivityAuthFailed),
                                      backgroundColor: Colors.red,
                                    ),
                                  );
                                  if (mounted) {
                                    setState(() {
                                      _isSyncing = false;
                                    });
                                  }
                                  return;
                                }

                                if (!context.mounted) return;
                                await _handleSync(
                                  context,
                                  accessToken,
                                  transactionsProvider,
                                );
                              },
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.blue.shade900,
                        ),
                        child: _isSyncing
                            ? SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.blue.shade900),
                                ),
                              )
                            : Text(l.connectivitySyncNow),
                      );
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
