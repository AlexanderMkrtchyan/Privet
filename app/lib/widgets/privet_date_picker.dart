import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme.dart';

/// Reminder date picker.
///
/// Replaces Material `showDatePicker`: Material renders each day cell with
/// `InkResponse`, whose adaptive cursor resolves to `basic` (arrow) off-web,
/// so the day numbers never show a pointer on the desktop app. Every control
/// here uses `InkWell(mouseCursor: SystemMouseCursors.click)` so the whole
/// calendar reads as clickable on every platform, in PrivetTheme.
class PrivetDateDialog extends StatefulWidget {
  const PrivetDateDialog({
    super.key,
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
  });

  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;

  @override
  State<PrivetDateDialog> createState() => _PrivetDateDialogState();
}

class _PrivetDateDialogState extends State<PrivetDateDialog> {
  static const List<String> _weekdays = [
    'Su',
    'Mo',
    'Tu',
    'We',
    'Th',
    'Fr',
    'Sa',
  ];
  static const List<String> _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  late DateTime _selected;
  late DateTime _viewMonth;

  @override
  void initState() {
    super.initState();
    _selected = _clamp(widget.initialDate);
    _viewMonth = DateTime(_selected.year, _selected.month);
  }

  DateTime _clamp(DateTime d) {
    if (d.isBefore(widget.firstDate)) return widget.firstDate;
    if (d.isAfter(widget.lastDate)) return widget.lastDate;
    return d;
  }

  DateTime _firstOf(DateTime d) => DateTime(d.year, d.month, 1);

  bool _canPrev() =>
      _firstOf(DateTime(_viewMonth.year, _viewMonth.month - 1, 1))
          .isAfter(_firstOf(widget.firstDate));

  bool _canNext() =>
      _firstOf(DateTime(_viewMonth.year, _viewMonth.month + 1, 1))
          .isBefore(_firstOf(widget.lastDate));

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final daysInMonth =
        DateTime(_viewMonth.year, _viewMonth.month + 1, 0).day;
    // DateTime.weekday: 1=Mon .. 7=Sun. Sunday-start grid → 0 leading blanks.
    final leadingBlanks =
        DateTime(_viewMonth.year, _viewMonth.month, 1).weekday % 7;
    final rows = ((leadingBlanks + daysInMonth) / 7).ceil();

    return Dialog(
      backgroundColor: PrivetTheme.panelElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: _canPrev() ? _prevMonth : null,
                  tooltip: 'Previous month',
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                Expanded(
                  child: Text(
                    '${_months[_viewMonth.month - 1]} ${_viewMonth.year}',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.syne(
                      color: PrivetTheme.paper,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _canNext() ? _nextMonth : null,
                  tooltip: 'Next month',
                  icon: const Icon(Icons.chevron_right_rounded),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                for (final w in _weekdays)
                  Expanded(
                    child: Center(
                      child: Text(
                        w,
                        style: GoogleFonts.dmSans(
                          color: PrivetTheme.mist,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            for (var r = 0; r < rows; r++)
              _buildRow(r, leadingBlanks, daysInMonth, today),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    'Cancel',
                    style: GoogleFonts.dmSans(color: PrivetTheme.mist),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: PrivetTheme.signal,
                  ),
                  onPressed: () => Navigator.of(context).pop(_selected),
                  child: Text(
                    'OK',
                    style: GoogleFonts.dmSans(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _prevMonth() =>
      setState(() => _viewMonth = DateTime(_viewMonth.year, _viewMonth.month - 1));

  void _nextMonth() =>
      setState(() => _viewMonth = DateTime(_viewMonth.year, _viewMonth.month + 1));

  Widget _buildRow(int row, int leadingBlanks, int daysInMonth, DateTime today) {
    final cells = <Widget>[];
    for (var col = 0; col < 7; col++) {
      final day = row * 7 + col - leadingBlanks + 1;
      if (day < 1 || day > daysInMonth) {
        cells.add(const Expanded(child: SizedBox(height: 36)));
        continue;
      }
      final dt = DateTime(_viewMonth.year, _viewMonth.month, day);
      final enabled =
          !dt.isBefore(widget.firstDate) && !dt.isAfter(widget.lastDate);
      cells.add(_DayCell(
        date: dt,
        isSelected: _sameDay(dt, _selected),
        isToday: _sameDay(dt, today),
        enabled: enabled,
        onTap: () => setState(() => _selected = dt),
      ));
    }
    return Row(children: cells);
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.date,
    required this.isSelected,
    required this.isToday,
    required this.enabled,
    required this.onTap,
  });

  final DateTime date;
  final bool isSelected;
  final bool isToday;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Center(
        child: InkWell(
          // Pointer hand on the day numbers on every platform (Material's
          // day cells use an adaptive arrow cursor off-web).
          mouseCursor: SystemMouseCursors.click,
          borderRadius: BorderRadius.circular(10),
          onTap: enabled ? onTap : null,
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isSelected ? PrivetTheme.signal : null,
              border: isToday && !isSelected
                  ? Border.all(color: PrivetTheme.signal, width: 1.4)
                  : null,
            ),
            child: Text(
              '${date.day}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected || isToday
                    ? FontWeight.w700
                    : FontWeight.w500,
                color: isSelected
                    ? PrivetTheme.onAccent
                    : enabled
                        ? PrivetTheme.paper
                        : PrivetTheme.mist.withValues(alpha: 0.4),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
