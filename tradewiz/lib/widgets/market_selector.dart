import 'package:flutter/material.dart';

import '../models/market.dart';
import '../theme_tradewizz.dart';

/// Compact dropdown to switch between supported markets.
class MarketSelector extends StatelessWidget {
  const MarketSelector({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final Market selected;
  final ValueChanged<Market> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      // The DropdownButton reserves extra internal space before its chevron,
      // so the right side reads looser than the left. Trim the right padding
      // to balance the flag/text inset on the left against the chevron.
      padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
      decoration: BoxDecoration(
        color: TWColors.bgElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TWColors.hairline),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<Market>(
          value: selected,
          isDense: true,
          borderRadius: BorderRadius.circular(12),
          dropdownColor: TWColors.bgElevated,
          style: const TextStyle(color: TWColors.textPrimary),
          icon: const Icon(Icons.keyboard_arrow_down,
              size: 20, color: TWColors.textSecondary),
          items: [
            for (final m in Market.values)
              DropdownMenuItem(
                value: m,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(m.flag),
                    const SizedBox(width: 8),
                    Text(
                      m.code,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          color: TWColors.textPrimary),
                    ),
                  ],
                ),
              ),
          ],
          onChanged: (m) {
            if (m != null) onChanged(m);
          },
        ),
      ),
    );
  }
}
