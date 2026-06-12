import 'package:flutter/material.dart';

import '../models/broker_app.dart';
import '../theme_tradewizz.dart';

/// A compact, branded logo mark for a [BrokerApp].
///
/// We do not bundle the brokers' copyrighted logo assets. Instead each broker
/// gets a recognizable monogram tile in its brand color — enough to scan the
/// list quickly while staying trademark-safe. If real logo assets are added
/// under `assets/brokers/<id>.png` later, this widget can switch to Image.asset.
class BrokerLogo extends StatelessWidget {
  const BrokerLogo({super.key, required this.broker, this.size = 36});

  final BrokerApp broker;
  final double size;

  /// Brand color per broker (approximate, for the monogram tile).
  static const Map<String, Color> _brandColor = {
    'stockbit': Color(0xFF1AAB5A), // Stockbit green
    'moomoo': Color(0xFFFF7A00), // Moomoo orange
    'ajaib': Color(0xFF6C5CE7), // Ajaib purple
    'ipot': Color(0xFFE53935), // IPOT red
    'mirae_hots': Color(0xFF0B5FFF), // Mirae blue
    'ibkr': Color(0xFFD81222), // Interactive Brokers red
  };

  /// Monogram shown on the tile.
  static const Map<String, String> _monogram = {
    'stockbit': 'S',
    'moomoo': 'm',
    'ajaib': 'A',
    'ipot': 'IP',
    'mirae_hots': 'M',
    'ibkr': 'IB',
  };

  Color get _color => _brandColor[broker.id] ?? TWColors.accent;
  String get _mark =>
      _monogram[broker.id] ?? broker.label.characters.first.toUpperCase();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _color,
            Color.lerp(_color, Colors.black, 0.22) ?? _color,
          ],
        ),
        borderRadius: BorderRadius.circular(size * 0.28),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        boxShadow: [
          BoxShadow(
            color: _color.withValues(alpha: 0.35),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        _mark,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: size * (_mark.length > 1 ? 0.34 : 0.46),
          letterSpacing: 0,
          height: 1,
        ),
      ),
    );
  }
}
