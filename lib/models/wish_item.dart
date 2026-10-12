import 'package:uuid/uuid.dart';

/// One Wishlist item. Stored as a record of `tasks.json` in the shape
/// BestToDo writes its tasks (Best Music's Wishlist used BestToDo's task
/// store until the two apps were split), flagged `isWish`. Fields this
/// class doesn't model are kept as they were read ([toJson] writes them
/// back), so nothing in an existing record is lost.
class WishItem {
  WishItem({
    String? uid,
    required this.title,
    this.description = '',
    this.label = '',
    this.isDone = false,
    this.isWish = true,
    this.createdAt,
    this.completedAt,
    Map<String, dynamic>? extra,
  })  : uid = (uid == null || uid.isEmpty) ? newUid() : uid,
        _extra = extra ?? const {};

  static String newUid() => const Uuid().v4();

  String uid;
  String title;
  String description;

  /// Comma/space separated tags, including the priority tags
  /// (`wish_priority.dart`).
  String label;
  bool isDone;

  /// False for a record that isn't a Wishlist item (kept, but not shown).
  bool isWish;
  DateTime? createdAt;
  DateTime? completedAt;

  final Map<String, dynamic> _extra;

  static const _known = {
    'uid',
    'title',
    'description',
    'label',
    'isDone',
    'isWish',
    'createdAt',
    'completedAt',
  };

  factory WishItem.fromJson(Map<String, dynamic> json) => WishItem(
        uid: json['uid'] as String?,
        title: json['title'] as String? ?? '',
        description: json['description'] as String? ?? '',
        label: json['label'] as String? ?? '',
        isDone: json['isDone'] as bool? ?? false,
        isWish: json['isWish'] as bool? ?? false,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
        completedAt: DateTime.tryParse(json['completedAt'] as String? ?? ''),
        extra: {
          for (final e in json.entries)
            if (!_known.contains(e.key)) e.key: e.value,
        },
      );

  Map<String, dynamic> toJson() => {
        ..._extra,
        'uid': uid,
        'title': title,
        'description': description,
        'label': label,
        'isDone': isDone,
        'isWish': isWish,
        'createdAt': createdAt?.toIso8601String(),
        'completedAt': completedAt?.toIso8601String(),
      };
}
