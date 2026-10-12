import '../models/wish_item.dart';

/// Priority labels a wishlist item can carry inside [WishItem.label],
/// ordered from lowest to highest. The same tokens BestToDo's Wishlist
/// uses, so items read the same in both apps.
const List<String> wishPriorityLabels = <String>[
  'priority-low',
  'priority-medium',
  'priority-high',
];

/// 0 for no priority label, 1..3 for low..high.
int wishPriorityRank(WishItem item) {
  final labels = item.label
      .toLowerCase()
      .split(RegExp(r'[,\s]+'))
      .map((label) => label.trim())
      .toSet();
  for (var i = wishPriorityLabels.length - 1; i >= 0; i--) {
    if (labels.contains(wishPriorityLabels[i])) return i + 1;
  }
  return 0;
}
