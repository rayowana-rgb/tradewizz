/// Broker types supported by the connection framework.
enum BrokerType { moomoo, ibkr }

extension BrokerTypeX on BrokerType {
  String get wire => this == BrokerType.moomoo ? 'MOOMOO' : 'IBKR';
  String get label =>
      this == BrokerType.moomoo ? 'Moomoo' : 'Interactive Brokers';

  /// Only Moomoo is implemented today; IBKR is an architecture stub.
  bool get isAvailable => this == BrokerType.moomoo;

  static BrokerType fromWire(String? w) =>
      (w?.toUpperCase() == 'IBKR') ? BrokerType.ibkr : BrokerType.moomoo;
}

/// A user's connection to a broker (GET /v1/brokers).
class BrokerConnection {
  const BrokerConnection({
    required this.id,
    required this.brokerType,
    required this.displayName,
    required this.isActive,
    required this.createdAt,
  });

  final int id;
  final BrokerType brokerType;
  final String displayName;
  final bool isActive;
  final String createdAt;

  factory BrokerConnection.fromJson(Map<String, dynamic> j) => BrokerConnection(
        id: (j['id'] as num?)?.toInt() ?? 0,
        brokerType: BrokerTypeX.fromWire(j['broker_type'] as String?),
        displayName: j['display_name'] as String? ?? '',
        isActive: j['is_active'] as bool? ?? false,
        createdAt: j['created_at'] as String? ?? '',
      );
}
