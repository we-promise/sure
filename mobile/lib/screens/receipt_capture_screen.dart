import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/account.dart';
import '../providers/auth_provider.dart';
import '../providers/privacy_provider.dart';
import '../services/app_lock_guard.dart';
import '../services/preferences_service.dart';
import '../services/receipts_service.dart';
import '../utils/money_masker.dart';

/// Scan (or pick) a receipt and upload it to the account it was paid from.
/// The camera goes through the system document scanner, which finds the
/// receipt's edges and straightens it, so only the receipt reaches the server.
/// The server creates the transaction and reads the receipt afterwards.
class ReceiptCaptureScreen extends StatefulWidget {
  static const maxPhotos = 5;

  final List<Account> accounts;
  final String? initialAccountId;
  final ReceiptsService? service;
  final Future<String?> Function()? accessTokenLoader;

  /// Returns the scanned pages, or null when the user cancels.
  final Future<List<XFile>?> Function(int maxPages)? scanDocument;
  final Future<List<XFile>> Function()? pickFromGallery;

  const ReceiptCaptureScreen({
    super.key,
    required this.accounts,
    this.initialAccountId,
    this.service,
    this.accessTokenLoader,
    this.scanDocument,
    this.pickFromGallery,
  });

  @override
  State<ReceiptCaptureScreen> createState() => _ReceiptCaptureScreenState();
}

class _ReceiptCaptureScreenState extends State<ReceiptCaptureScreen> {
  final List<XFile> _photos = [];
  String? _accountId;
  // Set once the user picks an account, so the remembered one, read
  // asynchronously, doesn't replace their choice.
  bool _accountPicked = false;
  bool _uploading = false;
  late final ReceiptsService _service = widget.service ?? ReceiptsService();

  @override
  void initState() {
    super.initState();
    _accountId = widget.accounts.isNotEmpty ? widget.accounts.first.id : null;
    if (widget.accounts
        .any((account) => account.id == widget.initialAccountId)) {
      _accountId = widget.initialAccountId;
      return;
    }
    PreferencesService.instance.getLastReceiptAccountId().then((lastId) {
      if (!mounted || lastId == null || _accountPicked) return;
      if (widget.accounts.any((account) => account.id == lastId)) {
        setState(() => _accountId = lastId);
      }
    });
  }

  int get _remainingSlots => ReceiptCaptureScreen.maxPhotos - _photos.length;

  Future<List<XFile>?> _scan(int maxPages) async {
    if (widget.scanDocument != null) return widget.scanDocument!(maxPages);

    // The scanner and the picker are native screens: opening them mustn't
    // lock the app and ask for Face ID again.
    final paths = await AppLockGuard.instance.whileNativeScreenOpen(
      () => CunningDocumentScanner.getPictures(
        noOfPages: maxPages,
        scannerSource: ScannerSource.camera,
        iosScannerOptions: IosScannerOptions(
          imageFormat: IosImageFormat.jpg,
          jpgCompressionQuality: 0.85,
          showFilterBar: false,
        ),
      ),
    );
    return paths?.map(XFile.new).toList();
  }

  Future<List<XFile>> _pickFromGallery() {
    if (widget.pickFromGallery != null) return widget.pickFromGallery!();
    return AppLockGuard.instance.whileNativeScreenOpen(() => ImagePicker()
        .pickMultiImage(imageQuality: 85, maxWidth: 2000, maxHeight: 2000));
  }

  Future<void> _scanReceipt() async {
    final List<XFile>? scanned;
    try {
      scanned = await _scan(_remainingSlots);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(AppLocalizations.of(context)
                .receiptScannerFailed(error.toString()))),
      );
      return;
    }
    _addPhotos(scanned ?? []);
  }

  Future<void> _chooseFromGallery() async {
    final List<XFile> picked;
    try {
      picked = await _pickFromGallery();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(AppLocalizations.of(context)
                .receiptGalleryFailed(error.toString()))),
      );
      return;
    }
    _addPhotos(picked);
  }

  void _addPhotos(List<XFile> picked) {
    if (!mounted || picked.isEmpty) return;
    setState(() {
      _photos.addAll(picked.take(_remainingSlots));
    });
  }

  Future<String?> _accessToken() {
    if (widget.accessTokenLoader != null) return widget.accessTokenLoader!();
    return context.read<AuthProvider>().getValidAccessToken();
  }

  Future<void> _upload() async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final accountId = _accountId!;

    setState(() => _uploading = true);
    try {
      final token = await _accessToken();
      if (token == null)
        throw const ReceiptUploadException('unauthorized', unauthorized: true);

      await _service.upload(
          accessToken: token, accountId: accountId, files: _photos);
      await PreferencesService.instance.setLastReceiptAccountId(accountId);

      messenger.showSnackBar(SnackBar(content: Text(l.receiptUploaded)));
      // The screen may have been closed during the upload; its navigator is then stale.
      if (mounted && navigator.canPop()) navigator.pop(true);
    } catch (error) {
      messenger.showSnackBar(
          SnackBar(content: Text(l.receiptUploadFailed(error.toString()))));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final hideAmounts = context.watch<PrivacyProvider>().hidden;
    final canAddMore =
        _photos.length < ReceiptCaptureScreen.maxPhotos && !_uploading;
    final canUpload = _photos.isNotEmpty && _accountId != null && !_uploading;

    return Scaffold(
      appBar: AppBar(title: Text(l.receiptScanTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_photos.isNotEmpty)
              SizedBox(
                height: 120,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _photos.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) => _PhotoThumbnail(
                    photo: _photos[index],
                    removeTooltip: l.receiptRemovePhoto,
                    onRemove: _uploading
                        ? null
                        : () => setState(() => _photos.removeAt(index)),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Text(l.receiptMaxPhotos(ReceiptCaptureScreen.maxPhotos),
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: canAddMore ? _scanReceipt : null,
                    icon: const Icon(Icons.document_scanner_outlined),
                    label: Text(l.receiptTakePhoto),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: canAddMore ? _chooseFromGallery : null,
                    icon: const Icon(Icons.photo_library_outlined),
                    label: Text(l.receiptChooseFromGallery),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            DropdownButtonFormField<String>(
              value: _accountId,
              isExpanded: true,
              decoration: InputDecoration(labelText: l.receiptAccountLabel),
              items: [
                for (final account in widget.accounts)
                  DropdownMenuItem(
                    value: account.id,
                    child: _AccountOption(
                        account: account, hideAmounts: hideAmounts),
                  ),
              ],
              onChanged: _uploading
                  ? null
                  : (value) => setState(() {
                        _accountPicked = true;
                        _accountId = value;
                      }),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: canUpload ? _upload : null,
              child: _uploading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(l.receiptUpload),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhotoThumbnail extends StatelessWidget {
  final XFile photo;
  final String removeTooltip;
  final VoidCallback? onRemove;

  const _PhotoThumbnail(
      {required this.photo, required this.removeTooltip, this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: FutureBuilder(
            future: photo.readAsBytes(),
            builder: (context, snapshot) => snapshot.hasData
                ? Image.memory(snapshot.data!,
                    width: 90,
                    height: 120,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const _ThumbnailPlaceholder())
                : const _ThumbnailPlaceholder(),
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          child: IconButton(
            tooltip: removeTooltip,
            icon: const Icon(Icons.close),
            onPressed: onRemove,
          ),
        ),
      ],
    );
  }
}

class _ThumbnailPlaceholder extends StatelessWidget {
  const _ThumbnailPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 90,
      height: 120,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Icon(Icons.receipt_long_outlined),
    );
  }
}

class _AccountOption extends StatelessWidget {
  final Account account;
  final bool hideAmounts;

  const _AccountOption({required this.account, required this.hideAmounts});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(child: Text(account.name, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 8),
        Text(MoneyMasker.mask(account.balance, hidden: hideAmounts)),
        const SizedBox(width: 4),
        Text(
          account.currency,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
