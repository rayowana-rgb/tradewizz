/// Spec-named entry point for the glass card.
///
/// The implementation lives in [tw_cards.dart] alongside [TWFloatingCard]
/// (its cheaper opaque sibling). This file simply re-exports it so the
/// design-system filename matches the brand spec (`tw_glass_card.dart`).
library;

export 'tw_cards.dart' show TWGlassCard, TWFloatingCard;
