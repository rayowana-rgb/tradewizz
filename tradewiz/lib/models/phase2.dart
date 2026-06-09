/// Models for Phase 2 (retention) features: AI Morning Brief, AI Portfolio
/// Manager, Portfolio Journal, and in-app Notifications. All research/
/// simulation only — no broker data.
library;

import 'market.dart';

// =========================================================================
// AI Morning Brief
// =========================================================================
class BriefPick {
  const BriefPick({
    required this.symbol,
    required this.market,
    this.name = '',
    this.score = 0,
    this.signal = 'HOLD',
    this.reason = '',
  });

  final String symbol;
  final Market market;
  final String name;
  final double score;
  final String signal;
  final String reason;

  static BriefPick? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    return BriefPick(
      symbol: (j['symbol'] ?? '').toString(),
      market: Market.fromCode((j['market'] ?? 'US').toString()),
      name: (j['name'] ?? '').toString(),
      score: (j['score'] ?? 0).toDouble(),
      signal: (j['signal'] ?? 'HOLD').toString(),
      reason: (j['reason'] ?? '').toString(),
    );
  }
}

class MorningBrief {
  const MorningBrief({
    required this.market,
    this.title = 'AI Morning Brief',
    this.generatedAt = '',
    this.sessionDate = '',
    this.marketRegime = 'NEUTRAL',
    this.strongestSector = '',
    this.headline = '',
    this.topOpportunity,
    this.topMultibagger,
    this.notes = const [],
    this.cached = false,
  });

  final Market market;
  final String title;
  final String generatedAt;
  final String sessionDate;
  final String marketRegime;
  final String strongestSector;
  final String headline;
  final BriefPick? topOpportunity;
  final BriefPick? topMultibagger;
  final List<String> notes;
  final bool cached;

  factory MorningBrief.fromJson(Map<String, dynamic> j) {
    return MorningBrief(
      market: Market.fromCode((j['market'] ?? 'US').toString()),
      title: (j['title'] ?? 'AI Morning Brief').toString(),
      generatedAt: (j['generated_at'] ?? '').toString(),
      sessionDate: (j['session_date'] ?? '').toString(),
      marketRegime: (j['market_regime'] ?? 'NEUTRAL').toString(),
      strongestSector: (j['strongest_sector'] ?? '').toString(),
      headline: (j['headline'] ?? '').toString(),
      topOpportunity:
          BriefPick.fromJson(j['top_opportunity'] as Map<String, dynamic>?),
      topMultibagger:
          BriefPick.fromJson(j['top_multibagger'] as Map<String, dynamic>?),
      notes: (j['notes'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      cached: j['cached'] == true,
    );
  }
}

// =========================================================================
// AI Portfolio Manager
// =========================================================================
class PmRecommendation {
  const PmRecommendation({
    required this.kind,
    this.severity = 'info',
    this.symbol,
    this.title = '',
    this.message = '',
  });

  final String kind;
  final String severity; // info / warning / critical
  final String? symbol;
  final String title;
  final String message;

  factory PmRecommendation.fromJson(Map<String, dynamic> j) {
    return PmRecommendation(
      kind: (j['kind'] ?? '').toString(),
      severity: (j['severity'] ?? 'info').toString(),
      symbol: j['symbol']?.toString(),
      title: (j['title'] ?? '').toString(),
      message: (j['message'] ?? '').toString(),
    );
  }
}

class PortfolioManagerReport {
  const PortfolioManagerReport({
    required this.riskLevel,
    this.portfolioScore = 0,
    this.concentrationScore = 0,
    this.diversificationScore = 0,
    this.qualityScore = 0,
    this.cashPct = 0,
    this.largestPositionPct = 0,
    this.recommendations = const [],
  });

  final String riskLevel; // LOW / MODERATE / HIGH
  final double portfolioScore;
  final double concentrationScore;
  final double diversificationScore;
  final double qualityScore;
  final double cashPct;
  final double largestPositionPct;
  final List<PmRecommendation> recommendations;

  factory PortfolioManagerReport.fromJson(Map<String, dynamic> j) {
    return PortfolioManagerReport(
      riskLevel: (j['risk_level'] ?? 'MODERATE').toString(),
      portfolioScore: (j['portfolio_score'] ?? 0).toDouble(),
      concentrationScore: (j['concentration_score'] ?? 0).toDouble(),
      diversificationScore: (j['diversification_score'] ?? 0).toDouble(),
      qualityScore: (j['quality_score'] ?? 0).toDouble(),
      cashPct: (j['cash_pct'] ?? 0).toDouble(),
      largestPositionPct: (j['largest_position_pct'] ?? 0).toDouble(),
      recommendations: (j['recommendations'] as List<dynamic>? ?? [])
          .map((e) => PmRecommendation.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

// =========================================================================
// Portfolio Journal
// =========================================================================
class JournalEntry {
  const JournalEntry({
    required this.symbol,
    required this.market,
    this.buyDate = '',
    this.buyPrice = 0,
    this.quantity = 0,
    this.score = 0,
    this.signal = 'HOLD',
    this.radarRank,
    this.portfolioHealth = 0,
    this.sellDate,
    this.sellPrice,
    this.realizedReturn,
    this.status = 'OPEN',
  });

  final String symbol;
  final Market market;
  final String buyDate;
  final double buyPrice;
  final double quantity;
  final double score;
  final String signal;
  final int? radarRank;
  final double portfolioHealth;
  final String? sellDate;
  final double? sellPrice;
  final double? realizedReturn;
  final String status;

  bool get isClosed => status == 'CLOSED';

  factory JournalEntry.fromJson(Map<String, dynamic> j) {
    return JournalEntry(
      symbol: (j['symbol'] ?? '').toString(),
      market: Market.fromCode((j['market'] ?? 'US').toString()),
      buyDate: (j['buy_date'] ?? '').toString(),
      buyPrice: (j['buy_price'] ?? 0).toDouble(),
      quantity: (j['quantity'] ?? 0).toDouble(),
      score: (j['score'] ?? 0).toDouble(),
      signal: (j['signal'] ?? 'HOLD').toString(),
      radarRank: j['radar_rank'] == null
          ? null
          : (j['radar_rank'] as num).toInt(),
      portfolioHealth: (j['portfolio_health'] ?? 0).toDouble(),
      sellDate: j['sell_date']?.toString(),
      sellPrice:
          j['sell_price'] == null ? null : (j['sell_price'] as num).toDouble(),
      realizedReturn: j['realized_return'] == null
          ? null
          : (j['realized_return'] as num).toDouble(),
      status: (j['status'] ?? 'OPEN').toString(),
    );
  }
}

class JournalStats {
  const JournalStats({
    this.totalTrades = 0,
    this.openPositions = 0,
    this.winRate = 0,
    this.averageGain = 0,
    this.averageLoss = 0,
    this.bestTrade,
    this.worstTrade,
  });

  final int totalTrades;
  final int openPositions;
  final double winRate;
  final double averageGain;
  final double averageLoss;
  final JournalEntry? bestTrade;
  final JournalEntry? worstTrade;

  factory JournalStats.fromJson(Map<String, dynamic> j) {
    return JournalStats(
      totalTrades: (j['total_trades'] ?? 0 as num).toInt(),
      openPositions: (j['open_positions'] ?? 0 as num).toInt(),
      winRate: (j['win_rate'] ?? 0).toDouble(),
      averageGain: (j['average_gain'] ?? 0).toDouble(),
      averageLoss: (j['average_loss'] ?? 0).toDouble(),
      bestTrade: j['best_trade'] == null
          ? null
          : JournalEntry.fromJson(j['best_trade'] as Map<String, dynamic>),
      worstTrade: j['worst_trade'] == null
          ? null
          : JournalEntry.fromJson(j['worst_trade'] as Map<String, dynamic>),
    );
  }
}

// =========================================================================
// Notifications
// =========================================================================
class AppNotification {
  const AppNotification({
    required this.id,
    required this.notificationType,
    this.title = '',
    this.body = '',
    this.symbol,
    this.market,
    this.createdAt = '',
    this.read = false,
  });

  final int id;
  final String notificationType;
  final String title;
  final String body;
  final String? symbol;
  final String? market;
  final String createdAt;
  final bool read;

  factory AppNotification.fromJson(Map<String, dynamic> j) {
    return AppNotification(
      id: (j['id'] ?? 0 as num).toInt(),
      notificationType: (j['notification_type'] ?? '').toString(),
      title: (j['title'] ?? '').toString(),
      body: (j['body'] ?? '').toString(),
      symbol: j['symbol']?.toString(),
      market: j['market']?.toString(),
      createdAt: (j['created_at'] ?? '').toString(),
      read: j['read'] == true,
    );
  }
}

class NotificationList {
  const NotificationList({
    this.notifications = const [],
    this.unreadCount = 0,
  });

  final List<AppNotification> notifications;
  final int unreadCount;

  factory NotificationList.fromJson(Map<String, dynamic> j) {
    return NotificationList(
      notifications: (j['notifications'] as List<dynamic>? ?? [])
          .map((e) => AppNotification.fromJson(e as Map<String, dynamic>))
          .toList(),
      unreadCount: (j['unread_count'] ?? 0 as num).toInt(),
    );
  }
}
