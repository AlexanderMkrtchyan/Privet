import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models.dart';
import '../theme.dart';

enum SpendingPeriod { week, month, twoMonths, year }

extension SpendingPeriodX on SpendingPeriod {
  String get label {
    switch (this) {
      case SpendingPeriod.week:
        return 'Week';
      case SpendingPeriod.month:
        return 'Month';
      case SpendingPeriod.twoMonths:
        return '2 months';
      case SpendingPeriod.year:
        return 'Year';
    }
  }

  Duration get duration {
    switch (this) {
      case SpendingPeriod.week:
        return const Duration(days: 7);
      case SpendingPeriod.month:
        return const Duration(days: 30);
      case SpendingPeriod.twoMonths:
        return const Duration(days: 60);
      case SpendingPeriod.year:
        return const Duration(days: 365);
    }
  }
}

class _SpendingRow {
  const _SpendingRow({
    required this.label,
    required this.amountCents,
    required this.currency,
    required this.count,
  });

  final String label;
  final int amountCents;
  final String currency;
  final int count;
}

List<_SpendingRow> _aggregateSpending(
  List<PaymentReminder> payments,
  SpendingPeriod period,
) {
  final cutoff = DateTime.now().subtract(period.duration);
  final buckets = <String, _SpendingRow>{};

  for (final payment in payments) {
    if (!payment.paid) continue;
    for (final expense in payment.expenses) {
      final when = expense.createdAt ?? payment.paidAt;
      if (when == null || when.isBefore(cutoff)) continue;
      final key = '${payment.currency}\u0000${expense.label.trim().toLowerCase()}';
      final existing = buckets[key];
      if (existing == null) {
        buckets[key] = _SpendingRow(
          label: expense.label.trim().isEmpty ? 'Other' : expense.label.trim(),
          amountCents: expense.amountCents,
          currency: payment.currency,
          count: 1,
        );
      } else {
        buckets[key] = _SpendingRow(
          label: existing.label,
          amountCents: existing.amountCents + expense.amountCents,
          currency: existing.currency,
          count: existing.count + 1,
        );
      }
    }
  }

  final rows = buckets.values.toList()
    ..sort((a, b) => b.amountCents.compareTo(a.amountCents));
  return rows;
}

String _formatMoney(int cents, String currency) {
  const symbols = {'USD': '\$', 'EUR': '€', 'GBP': '£', 'RUB': '₽', 'UAH': '₴'};
  final sym = symbols[currency] ?? currency;
  final a = cents / 100.0;
  return a % 1 == 0 ? '$sym${a.toInt()}' : '$sym${a.toStringAsFixed(2)}';
}

Future<void> showPaymentSpendingInsights(
  BuildContext context, {
  required List<PaymentReminder> payments,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _PaymentSpendingInsightsDialog(payments: payments),
  );
}

class _PaymentSpendingInsightsDialog extends StatefulWidget {
  const _PaymentSpendingInsightsDialog({required this.payments});

  final List<PaymentReminder> payments;

  @override
  State<_PaymentSpendingInsightsDialog> createState() =>
      _PaymentSpendingInsightsDialogState();
}

class _PaymentSpendingInsightsDialogState
    extends State<_PaymentSpendingInsightsDialog> {
  SpendingPeriod _period = SpendingPeriod.month;

  static const _barColors = [
    Color(0xFFF0A83D),
    Color(0xFF3D9CF0),
    Color(0xFF9B7EDE),
    Color(0xFF5FD38D),
    Color(0xFFE86A6A),
    Color(0xFF56C8C8),
  ];

  @override
  Widget build(BuildContext context) {
    final rows = _aggregateSpending(widget.payments, _period);
    final byCurrency = <String, List<_SpendingRow>>{};
    for (final row in rows) {
      byCurrency.putIfAbsent(row.currency, () => []).add(row);
    }

    return AlertDialog(
      backgroundColor: PrivetTheme.panelElevated,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      title: Row(
        children: [
          Icon(Icons.insights_rounded, size: 20, color: const Color(0xFFF0A83D)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Spending overview',
              style: GoogleFonts.syne(
                color: PrivetTheme.mist,
                fontWeight: FontWeight.w700,
                fontSize: 18,
              ),
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: Icon(Icons.close_rounded, color: PrivetTheme.mist.withValues(alpha: 0.7)),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: SpendingPeriod.values.map((p) {
                final selected = _period == p;
                return MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => setState(() => _period = p),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: selected
                            ? const Color(0xFFF0A83D).withValues(alpha: 0.18)
                            : PrivetTheme.ink.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(99),
                        border: Border.all(
                          color: selected
                              ? const Color(0xFFF0A83D).withValues(alpha: 0.65)
                              : PrivetTheme.line,
                        ),
                      ),
                      child: Text(
                        p.label,
                        style: GoogleFonts.syne(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: selected ? const Color(0xFFF0A83D) : PrivetTheme.mist,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Column(
                  children: [
                    Icon(
                      Icons.bar_chart_rounded,
                      size: 40,
                      color: PrivetTheme.mist.withValues(alpha: 0.25),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'No spending in this ${_period.label.toLowerCase()}',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.ibmPlexSans(
                        fontSize: 13,
                        color: PrivetTheme.mist.withValues(alpha: 0.6),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Mark payments as paid and log purchases in each wallet.',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.ibmPlexSans(
                        fontSize: 12,
                        color: PrivetTheme.mist.withValues(alpha: 0.45),
                      ),
                    ),
                  ],
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.52,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final entry in byCurrency.entries) ...[
                        if (byCurrency.length > 1) ...[
                          Text(
                            entry.key,
                            style: GoogleFonts.ibmPlexSans(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: PrivetTheme.mist.withValues(alpha: 0.55),
                              letterSpacing: 0.4,
                            ),
                          ),
                          const SizedBox(height: 6),
                        ],
                        Builder(
                          builder: (context) {
                            final currencyRows = entry.value;
                            final total = currencyRows.fold<int>(
                              0,
                              (sum, r) => sum + r.amountCents,
                            );
                            final maxCents = currencyRows.first.amountCents;
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: PrivetTheme.ink.withValues(alpha: 0.35),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: const Color(0xFFF0A83D).withValues(alpha: 0.35),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Total spent',
                                        style: GoogleFonts.ibmPlexSans(
                                          fontSize: 11,
                                          color: PrivetTheme.mist.withValues(alpha: 0.6),
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        _formatMoney(total, entry.key),
                                        style: GoogleFonts.syne(
                                          fontSize: 26,
                                          fontWeight: FontWeight.w800,
                                          color: const Color(0xFFF0A83D),
                                        ),
                                      ),
                                      Text(
                                        '${currencyRows.fold<int>(0, (s, r) => s + r.count)} purchases · ${currencyRows.length} categories',
                                        style: GoogleFonts.ibmPlexSans(
                                          fontSize: 11,
                                          color: PrivetTheme.mist.withValues(alpha: 0.55),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 14),
                                ...currencyRows.asMap().entries.map((e) {
                                  final i = e.key;
                                  final row = e.value;
                                  final pct = maxCents == 0
                                      ? 0.0
                                      : row.amountCents / maxCents;
                                  final color = _barColors[i % _barColors.length];
                                  final share = total == 0
                                      ? 0
                                      : ((row.amountCents / total) * 100).round();
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 10),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.stretch,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                row.label,
                                                style: GoogleFonts.ibmPlexSans(
                                                  fontSize: 13,
                                                  color: PrivetTheme.paper,
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            Text(
                                              _formatMoney(row.amountCents, row.currency),
                                              style: GoogleFonts.syne(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w700,
                                                color: color,
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              '$share%',
                                              style: GoogleFonts.ibmPlexSans(
                                                fontSize: 11,
                                                color: PrivetTheme.mist.withValues(alpha: 0.5),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 5),
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(4),
                                          child: LinearProgressIndicator(
                                            value: pct.clamp(0.0, 1.0),
                                            minHeight: 8,
                                            backgroundColor:
                                                PrivetTheme.ink.withValues(alpha: 0.45),
                                            color: color,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }),
                              ],
                            );
                          },
                        ),
                        if (entry.key != byCurrency.keys.last) const SizedBox(height: 12),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class PaymentSpendingInsightsButton extends StatelessWidget {
  const PaymentSpendingInsightsButton({
    super.key,
    required this.payments,
  });

  final List<PaymentReminder> payments;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => showPaymentSpendingInsights(context, payments: payments),
          borderRadius: BorderRadius.circular(12),
          mouseCursor: SystemMouseCursors.click,
          child: Ink(
            decoration: BoxDecoration(
              color: PrivetTheme.ink.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFFF0A83D).withValues(alpha: 0.45),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bar_chart_rounded, size: 16, color: const Color(0xFFF0A83D)),
                  const SizedBox(width: 6),
                  Text(
                    'Spending chart',
                    style: GoogleFonts.syne(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFFF0A83D),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
