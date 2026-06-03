import 'package:flutter/material.dart';

import '../models/stock.dart';
import '../theme.dart';

/// A single row showing a stock's ticker, name, price and change.
class StockTile extends StatelessWidget {
  const StockTile({super.key, required this.stock, this.onTap});

  final Stock stock;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final changeColor = stock.isUp ? AppColors.up : AppColors.down;
    final sign = stock.isUp ? '+' : '';

    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        backgroundColor: AppColors.seed.withValues(alpha: 0.1),
        child: Text(
          stock.ticker.characters.take(2).toString(),
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13,
            color: AppColors.seed,
          ),
        ),
      ),
      title: Text(
        stock.ticker,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        stock.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            stock.price.toStringAsFixed(stock.price >= 100 ? 0 : 2),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(
            '$sign${stock.changePercent.toStringAsFixed(2)}%',
            style: TextStyle(
              color: changeColor,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
