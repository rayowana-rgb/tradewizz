import 'package:flutter/material.dart';

/// Screener categories carried over from the Telegram bot's tagging engine.
///
/// [wireName] is the snake_case identifier used in the API payload.
enum ScreenerCategory {
  bullish('bullish', 'Bullish', Color(0xFF1DB954), Icons.trending_up),
  bearish('bearish', 'Bearish', Color(0xFFE53935), Icons.trending_down),
  scalping('scalping', 'Scalping', Color(0xFFFB8C00), Icons.bolt),
  accumulation('accumulation', 'Accumulation', Color(0xFF1E88E5), Icons.layers),
  pullback('pullback', 'Pullback', Color(0xFF8E24AA), Icons.south_east),
  accumulationSilent('accumulation_silent', 'Silent Accumulation',
      Color(0xFF3949AB), Icons.volume_off),
  turnaroundMultibagger('turnaround_multibagger', 'Turnaround Multibagger',
      Color(0xFF00897B), Icons.rocket_launch),
  frequentlyTraded('frequently_traded', 'Frequently Traded', Color(0xFF6D4C41),
      Icons.repeat),
  shortCandidate('short_candidate', 'Short Candidate', Color(0xFFD81B60),
      Icons.south),
  araHunter('ara_hunter', 'ARA Hunter', Color(0xFFF4511E),
      Icons.local_fire_department);

  const ScreenerCategory(this.wireName, this.label, this.color, this.icon);

  final String wireName;
  final String label;
  final Color color;
  final IconData icon;

  static ScreenerCategory? fromWire(String? value) {
    if (value == null) return null;
    for (final c in ScreenerCategory.values) {
      if (c.wireName == value) return c;
    }
    return null;
  }
}
