import 'package:flutter/material.dart';

import '../pages/news_page.dart';
import '../repositories/stock_repository.dart';

/// AppBar icon (sits next to the notification bell) that opens the global
/// World Market News feed. Research only; no auth required.
class NewsButton extends StatelessWidget {
  const NewsButton({super.key, this.repository});

  final StockRepository? repository;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const Key('news_button'),
      tooltip: 'World market news',
      icon: const Icon(Icons.public_outlined),
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => NewsPage(repository: repository),
        ),
      ),
    );
  }
}
