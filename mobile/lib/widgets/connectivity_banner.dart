import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/connectivity_service.dart';
import '../providers/transactions_provider.dart';
import '../providers/auth_provider.dart';

class ConnectivityBanner extends StatefulWidget {
  const ConnectivityBanner({super.key});

  @override
  State<ConnectivityBanner> createState() => _ConnectivityBannerState();
}

class _ConnectivityBannerState extends State<ConnectivityBanner> {
  bool _isSyncing = false;

  Future<void> _handleSync(BuildContext context, String? accessToken, TransactionsProvider transactionsProvider) async {
    if (accessToken == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please sign in to sync transactions'),
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Transactions synced successfully'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to sync transactions. Please try again.'),
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
                        ? 'You are offline. Changes will sync when online.'
                        : '$pendingCount transaction${pendingCount == 1 ? '' : 's'} pending sync',
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
                                    const SnackBar(
                                      content: Text('Unable to authenticate. Please try again.'),
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
                            : const Text('Sync Now'),
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
