import 'package:flutter/material.dart';

import '../theme.dart';

/// Placeholder for upcoming AI-powered stock analysis.
class AiAnalysisPage extends StatelessWidget {
  const AiAnalysisPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: const LinearGradient(
              colors: [Color(0xFF6A11CB), Color(0xFF2575FC)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Icon(Icons.auto_awesome, color: Colors.white, size: 32),
              SizedBox(height: 12),
              Text(
                'AI Analysis',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 22,
                ),
              ),
              SizedBox(height: 6),
              Text(
                'Smart screening and insights are coming soon.',
                style: TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Planned Features',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
        ),
        const SizedBox(height: 12),
        ..._features.map(
          (f) => Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: AppColors.seed.withValues(alpha: 0.1),
                child: Icon(f.icon, color: AppColors.seed, size: 20),
              ),
              title: Text(
                f.title,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(f.subtitle),
              trailing: const Icon(Icons.lock_clock, size: 18, color: Colors.grey),
            ),
          ),
        ),
      ],
    );
  }
}

class _Feature {
  const _Feature(this.icon, this.title, this.subtitle);
  final IconData icon;
  final String title;
  final String subtitle;
}

const _features = [
  _Feature(Icons.search, 'Smart Screener',
      'Filter stocks by fundamentals and technicals.'),
  _Feature(Icons.insights, 'Trend Signals',
      'AI-detected momentum and reversal patterns.'),
  _Feature(Icons.summarize, 'Earnings Summaries',
      'Plain-language takes on financial reports.'),
  _Feature(Icons.chat_bubble_outline, 'Ask TradeWiz',
      'Chat with an analyst about any ticker.'),
];
