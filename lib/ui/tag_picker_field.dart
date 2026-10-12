import 'package:flutter/material.dart';

/// Splits a comma/space separated tag string into tokens (trimmed, empty
/// and case-insensitive duplicates dropped).
List<String> splitTags(String value) {
  final seen = <String>{};
  return [
    for (final raw in value.split(RegExp(r'[,\s]+')))
      if (raw.trim().isNotEmpty && seen.add(raw.trim().toLowerCase()))
        raw.trim(),
  ];
}

/// Joins tags back into the stored form.
String joinTags(Iterable<String> tags) => tags.join(', ');

/// Chip-based tag editor: the current tags as removable chips, and an "Add
/// tag" chip that opens a searchable list of [knownTags] (checkbox-toggled)
/// which also accepts a typed name to create a new one.
class TagPickerField extends StatefulWidget {
  const TagPickerField({
    super.key,
    required this.value,
    required this.onChanged,
    this.knownTags = const [],
    this.fieldLabel = 'Tags',
  });

  /// Comma separated tags.
  final String value;
  final ValueChanged<String> onChanged;

  /// Tags offered in the picker besides the ones already set (e.g. every tag
  /// used on another item).
  final List<String> knownTags;
  final String fieldLabel;

  @override
  State<TagPickerField> createState() => _TagPickerFieldState();
}

class _TagPickerFieldState extends State<TagPickerField> {
  late List<String> _tags = splitTags(widget.value);

  @override
  void didUpdateWidget(covariant TagPickerField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) _tags = splitTags(widget.value);
  }

  void _commit(List<String> tags) {
    setState(() => _tags = tags);
    widget.onChanged(joinTags(tags));
  }

  Future<void> _openPicker() async {
    final result = await showDialog<List<String>>(
      context: context,
      builder: (_) =>
          _TagPickerDialog(initialSelected: _tags, knownTags: widget.knownTags),
    );
    if (result != null) _commit(result);
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.fieldLabel,
                style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (var i = 0; i < _tags.length; i++)
                  InputChip(
                    label: Text(_tags[i]),
                    onDeleted: () => _commit([..._tags]..removeAt(i)),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.add, size: 18),
                  label: const Text('Add tag'),
                  onPressed: _openPicker,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The selection list: a search/create field on top, then every known tag
/// as a checkable row (filtered by the search text), with an "Add" row
/// whenever the typed text isn't a known tag. Owns its own controller so the
/// exit animation never touches a disposed one.
class _TagPickerDialog extends StatefulWidget {
  const _TagPickerDialog(
      {required this.initialSelected, required this.knownTags});

  final List<String> initialSelected;
  final List<String> knownTags;

  @override
  State<_TagPickerDialog> createState() => _TagPickerDialogState();
}

class _TagPickerDialogState extends State<_TagPickerDialog> {
  late final TextEditingController _searchController;
  late final List<String> _selected = [...widget.initialSelected];
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController()
      ..addListener(() => setState(() => _query = _searchController.text));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _isSelected(String name) =>
      _selected.any((t) => t.toLowerCase() == name.toLowerCase());

  void _toggle(String name) {
    setState(() {
      final i =
          _selected.indexWhere((t) => t.toLowerCase() == name.toLowerCase());
      if (i >= 0) {
        _selected.removeAt(i);
      } else {
        _selected.add(name);
      }
    });
  }

  void _addCustom() {
    final text = _searchController.text.trim();
    if (text.isEmpty) return;
    if (!_isSelected(text)) _toggle(text);
    _searchController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final seen = <String>{};
    final names = [
      for (final n in [...widget.knownTags, ..._selected])
        if (seen.add(n.toLowerCase())) n,
    ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final query = _query.trim().toLowerCase();
    final filtered = query.isEmpty
        ? names
        : names.where((n) => n.toLowerCase().contains(query)).toList();
    final exactMatch = names.any((n) => n.toLowerCase() == query);
    return AlertDialog(
      title: const Text('Tags'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _searchController,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Search or add a tag',
                prefixIcon: Icon(Icons.search),
              ),
              onSubmitted: (_) => _addCustom(),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 320,
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (query.isNotEmpty && !exactMatch)
                    ListTile(
                      leading: const Icon(Icons.add),
                      title: Text('Add "${_query.trim()}"'),
                      onTap: _addCustom,
                    ),
                  for (final name in filtered)
                    CheckboxListTile(
                      value: _isSelected(name),
                      title: Text(name),
                      controlAffinity: ListTileControlAffinity.leading,
                      onChanged: (_) => _toggle(name),
                    ),
                  if (filtered.isEmpty && query.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('No tags yet — type to add one.'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(_selected),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
