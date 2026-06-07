import 'package:flutter/material.dart';

import '../models/broker_connection.dart';
import '../repositories/stock_repository.dart';
import '../services/api_client.dart';
import '../services/auth_scope.dart';
import '../theme.dart';

/// Account -> Broker Connections. Lists supported brokers (Moomoo, IBKR) with
/// Connect / Disconnect. IBKR is shown but marked unavailable (stub).
class BrokerConnectionsPage extends StatefulWidget {
  const BrokerConnectionsPage({super.key, required this.repository});

  final StockRepository repository;

  @override
  State<BrokerConnectionsPage> createState() => _BrokerConnectionsPageState();
}

class _BrokerConnectionsPageState extends State<BrokerConnectionsPage> {
  bool _loading = true;
  String? _error;
  List<BrokerConnection> _connections = const [];

  String? get _token => AuthScope.read(context).token;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final token = _token;
    if (token == null) {
      setState(() {
        _loading = false;
        _error = 'Not signed in.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final conns = await widget.repository.brokerConnections(token);
      if (!mounted) return;
      setState(() => _connections = conns);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  BrokerConnection? _connectionFor(BrokerType type) {
    for (final c in _connections) {
      if (c.brokerType == type && c.isActive) return c;
    }
    return null;
  }

  Future<void> _connect(BrokerType type) async {
    final token = _token;
    if (token == null) return;
    setState(() => _error = null);
    try {
      await widget.repository.connectBroker(token, type);
      await _load();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _disconnect(BrokerConnection conn) async {
    final token = _token;
    if (token == null) return;
    setState(() => _error = null);
    try {
      await widget.repository.disconnectBroker(token, conn.id);
      await _load();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Broker Connections')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(_error!,
                          key: const Key('broker_error'),
                          style: const TextStyle(color: Colors.red)),
                    ),
                  for (final type in BrokerType.values)
                    _BrokerTile(
                      type: type,
                      connection: _connectionFor(type),
                      onConnect: () => _connect(type),
                      onDisconnect: () {
                        final c = _connectionFor(type);
                        if (c != null) _disconnect(c);
                      },
                    ),
                ],
              ),
      ),
    );
  }
}

class _BrokerTile extends StatelessWidget {
  const _BrokerTile({
    required this.type,
    required this.connection,
    required this.onConnect,
    required this.onDisconnect,
  });

  final BrokerType type;
  final BrokerConnection? connection;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final connected = connection != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: AppColors.seed.withValues(alpha: 0.1),
              child: const Icon(Icons.account_balance, color: AppColors.seed),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(type.label,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(
                    connected
                        ? 'Connected'
                        : (type.isAvailable ? 'Not connected' : 'Coming soon'),
                    style: TextStyle(
                      color: connected ? AppColors.up : Colors.grey,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            if (connected)
              OutlinedButton(
                key: Key('disconnect_${type.wire}'),
                style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.down),
                onPressed: onDisconnect,
                child: const Text('Disconnect'),
              )
            else
              FilledButton(
                key: Key('connect_${type.wire}'),
                onPressed: type.isAvailable ? onConnect : null,
                child: const Text('Connect'),
              ),
          ],
        ),
      ),
    );
  }
}
