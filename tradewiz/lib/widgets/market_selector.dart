import 'package:flutter/material.dart';

import '../models/market.dart';

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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE0E3E7)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<Market>(
          value: selected,
          isDense: true,
          borderRadius: BorderRadius.circular(12),
          icon: const Icon(Icons.keyboard_arrow_down, size: 20),
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
                      style: const TextStyle(fontWeight: FontWeight.w600),
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
