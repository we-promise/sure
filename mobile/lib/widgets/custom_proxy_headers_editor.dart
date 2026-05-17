import 'package:flutter/material.dart';

import '../models/custom_proxy_header.dart';

class CustomProxyHeadersEditor extends StatefulWidget {
  final List<CustomProxyHeader> initialHeaders;
  final ValueChanged<List<CustomProxyHeader>> onChanged;

  const CustomProxyHeadersEditor({
    super.key,
    required this.initialHeaders,
    required this.onChanged,
  });

  @override
  State<CustomProxyHeadersEditor> createState() => _CustomProxyHeadersEditorState();
}

class _CustomProxyHeadersEditorState extends State<CustomProxyHeadersEditor> {
  late List<_HeaderDraft> _drafts;

  @override
  void initState() {
    super.initState();
    _drafts = widget.initialHeaders
        .map((header) => _HeaderDraft(name: header.name, value: header.value))
        .toList();
  }

  void _notifyChanged() {
    widget.onChanged(
      _drafts
          .map((draft) => CustomProxyHeader(name: draft.name.text, value: draft.value.text))
          .where((header) => header.isComplete)
          .toList(),
    );
  }

  void _addHeader() {
    setState(() => _drafts.add(_HeaderDraft()));
  }

  void _removeHeader(int index) {
    setState(() {
      final draft = _drafts.removeAt(index);
      draft.dispose();
    });
    _notifyChanged();
  }

  @override
  void dispose() {
    for (final draft in _drafts) {
      draft.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < _drafts.length; index++) ...[
          _HeaderRow(
            draft: _drafts[index],
            onChanged: _notifyChanged,
            onRemove: () => _removeHeader(index),
          ),
          const SizedBox(height: 12),
        ],
        OutlinedButton.icon(
          onPressed: _addHeader,
          icon: const Icon(Icons.add),
          label: const Text('Add header'),
        ),
      ],
    );
  }
}

class _HeaderRow extends StatelessWidget {
  final _HeaderDraft draft;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  const _HeaderRow({
    required this.draft,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            children: [
              TextFormField(
                controller: draft.name,
                decoration: const InputDecoration(
                  labelText: 'Header name',
                  hintText: 'X-Auth-Token',
                ),
                validator: (value) => CustomProxyHeader.validateName(value ?? ''),
                onChanged: (_) => onChanged(),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: draft.value,
                decoration: const InputDecoration(
                  labelText: 'Header value',
                ),
                obscureText: true,
                validator: (value) => CustomProxyHeader.validateValue(value ?? ''),
                onChanged: (_) => onChanged(),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Remove header',
          icon: const Icon(Icons.delete_outline),
          onPressed: onRemove,
        ),
      ],
    );
  }
}

class _HeaderDraft {
  final TextEditingController name;
  final TextEditingController value;

  _HeaderDraft({String name = '', String value = ''})
      : name = TextEditingController(text: name),
        value = TextEditingController(text: value);

  void dispose() {
    name.dispose();
    value.dispose();
  }
}
