import 'dart:async';

import 'package:flutter/material.dart';

import '../services/user_service.dart';

class StreakCalendarScreen extends StatefulWidget {
  final String? userId;
  final Set<String> attendanceDays;
  final Set<String> cookingDays;
  final bool includeTodayAttendance;

  const StreakCalendarScreen({
    super.key,
    this.userId,
    required this.attendanceDays,
    required this.cookingDays,
    this.includeTodayAttendance = false,
  });

  @override
  State<StreakCalendarScreen> createState() => _StreakCalendarScreenState();
}

class _StreakCalendarScreenState extends State<StreakCalendarScreen> {
  late DateTime _visibleMonth;
  late Set<String> _attendanceDays;
  late Set<String> _cookingDays;
  final UserService _userService = UserService();

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _visibleMonth = DateTime(now.year, now.month);
    _attendanceDays = Set<String>.from(widget.attendanceDays);
    _cookingDays = Set<String>.from(widget.cookingDays);
    final userId = widget.userId?.trim();
    if (userId != null && userId.isNotEmpty) {
      unawaited(_reloadStreakDays(userId));
    }
  }

  Future<void> _reloadStreakDays(String userId) async {
    final streakDays = await _userService.getUserStreakDays(
      userId,
      forceServer: true,
    );
    if (!mounted) return;
    setState(() {
      _attendanceDays = streakDays.attendanceDays;
      _cookingDays = streakDays.cookingDays;
    });
  }

  bool get _isViewingCurrentMonth {
    final now = DateTime.now();
    return _visibleMonth.year == now.year && _visibleMonth.month == now.month;
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFFFF6B00);
    const darkAccent = Color(0xFFD94F00);
    final attendanceDays = _effectiveAttendanceDays();
    final cookingDays = _effectiveCookingDays();
    final attendanceStreak = _currentStreak(attendanceDays);
    final attendanceMonthlyCount = _countDaysInMonth(
      attendanceDays,
      _visibleMonth,
    );
    final cookingMonthlyCount = _countDaysInMonth(cookingDays, _visibleMonth);
    final heroStreakValue = _isViewingCurrentMonth
        ? attendanceStreak
        : attendanceMonthlyCount;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF8FAFC),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: const Text(
          '출석·요리 캘린더',
          style: TextStyle(
            fontFamily: 'Pretendard',
            color: Color(0xFF111827),
            fontSize: 18,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.4,
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 2, 20, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeroCard(
                accent: accent,
                darkAccent: darkAccent,
                heroStreakValue: heroStreakValue,
                isViewingCurrentMonth: _isViewingCurrentMonth,
                attendanceMonthlyCount: attendanceMonthlyCount,
                cookingMonthlyCount: cookingMonthlyCount,
              ),
              const SizedBox(height: 22),
              _buildMonthHeader(),
              const SizedBox(height: 12),
              _buildStatsRow(
                accent: accent,
                attendanceMonthlyCount: attendanceMonthlyCount,
                cookingMonthlyCount: cookingMonthlyCount,
              ),
              const SizedBox(height: 14),
              _buildCalendarCard(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeroCard({
    required Color accent,
    required Color darkAccent,
    required int heroStreakValue,
    required bool isViewingCurrentMonth,
    required int attendanceMonthlyCount,
    required int cookingMonthlyCount,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [darkAccent, accent],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.24),
            blurRadius: 28,
            offset: const Offset(0, 14),
            spreadRadius: -16,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '$heroStreakValue',
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            color: Colors.white,
                            fontSize: 50,
                            fontWeight: FontWeight.w900,
                            height: 0.95,
                            letterSpacing: -1.8,
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.only(left: 3, bottom: 6),
                          child: Text(
                            '일',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      isViewingCurrentMonth
                          ? '매일의 요리가 기록으로 쌓여요'
                          : '이 달 출석 $attendanceMonthlyCount일 · 요리 $cookingMonthlyCount일',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        color: Colors.white.withValues(alpha: 0.92),
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ],
                ),
              ),
              Image.asset(
                'assets/icons/streak_main_3d.png',
                width: 78,
                height: 78,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMonthHeader() {
    return Row(
      children: [
        Expanded(
          child: Text(
            '${_visibleMonth.year}.${_visibleMonth.month.toString().padLeft(2, '0')}',
            style: const TextStyle(
              fontFamily: 'Pretendard',
              color: Color(0xFF111827),
              fontSize: 26,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.8,
            ),
          ),
        ),
        _buildMonthButton(
          icon: Icons.chevron_left_rounded,
          onTap: () => setState(() {
            _visibleMonth = DateTime(
              _visibleMonth.year,
              _visibleMonth.month - 1,
            );
          }),
        ),
        const SizedBox(width: 4),
        _buildMonthButton(
          icon: Icons.chevron_right_rounded,
          onTap: () => setState(() {
            _visibleMonth = DateTime(
              _visibleMonth.year,
              _visibleMonth.month + 1,
            );
          }),
        ),
      ],
    );
  }

  Widget _buildMonthButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          width: 34,
          height: 34,
          child: Icon(icon, color: const Color(0xFF4B5563), size: 25),
        ),
      ),
    );
  }

  Widget _buildStatsRow({
    required Color accent,
    required int attendanceMonthlyCount,
    required int cookingMonthlyCount,
  }) {
    return Row(
      children: [
        Expanded(
          child: _buildStatPill(
            accent: const Color(0xFFFFA15C),
            iconAsset: 'assets/icons/streak_flame_3d.png',
            label: '출석',
            value: '$attendanceMonthlyCount일',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildStatPill(
            accent: accent,
            iconAsset: 'assets/icons/streak_cook_3d.png',
            label: '요리',
            value: '$cookingMonthlyCount일',
          ),
        ),
      ],
    );
  }

  Widget _buildStatPill({
    required Color accent,
    required String iconAsset,
    required String label,
    required String value,
  }) {
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFF1F3F5), width: 1),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Image.asset(
            iconAsset,
            width: label == '요리' ? 26 : 22,
            height: label == '요리' ? 26 : 22,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
          ),
          const SizedBox(width: 7),
          Text(
            label,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              color: Color(0xFF6B7280),
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            value,
            style: TextStyle(
              fontFamily: 'Pretendard',
              color: accent,
              fontSize: 13,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCalendarCard() {
    final monthStart = DateTime(_visibleMonth.year, _visibleMonth.month, 1);
    final monthEnd = DateTime(_visibleMonth.year, _visibleMonth.month + 1, 0);
    final calendarStart = _startOfWeek(monthStart);
    final calendarEnd = _startOfWeek(monthEnd).add(const Duration(days: 6));
    final weekRowCount =
        (calendarEnd.difference(calendarStart).inDays ~/ 7) + 1;
    const weekLabels = <String>['일', '월', '화', '수', '목', '금', '토'];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFF1F3F5), width: 1),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final dayCellSize = constraints.maxWidth / 7;

          return Column(
            children: [
              Row(
                children: [
                  for (final label in weekLabels)
                    SizedBox(
                      width: dayCellSize,
                      child: Center(
                        child: Text(
                          label,
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            color: Color(0xFF8B95A1),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              for (
                var weekIndex = 0;
                weekIndex < weekRowCount;
                weekIndex++
              ) ...[
                Row(
                  children: [
                    for (var weekday = 0; weekday < 7; weekday++)
                      SizedBox(
                        width: dayCellSize,
                        height: 48,
                        child: _buildDayCell(
                          day: calendarStart.add(
                            Duration(days: weekIndex * 7 + weekday),
                          ),
                          visibleMonth: _visibleMonth,
                        ),
                      ),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildDayCell({
    required DateTime day,
    required DateTime visibleMonth,
  }) {
    if (day.year != visibleMonth.year || day.month != visibleMonth.month) {
      return const SizedBox.shrink();
    }

    final today = _startOfDay(DateTime.now());
    final isToday = _isSameDay(day, today);
    final key = _dayKey(day);
    final hasCooking = _effectiveCookingDays().contains(key);
    final hasAttendance = _effectiveAttendanceDays().contains(key);
    final bool isPast = day.isBefore(today);
    final DateTime? firstActivity = _firstActivityDay();
    final bool showIce = isPast &&
        !hasCooking &&
        !hasAttendance &&
        firstActivity != null &&
        !day.isBefore(firstActivity);
    final Color backgroundColor = hasCooking
        ? const Color(0xFFFF6B00)
        : hasAttendance
        ? const Color(0xFFFFA15C)
        : showIce
        ? const Color(0xFFEAF4FF)
        : const Color(0xFFF6F8FA);
    final Color foregroundColor = hasCooking
        ? Colors.white
        : hasAttendance
        ? Colors.white
        : const Color(0xFF97A3B3);
    final bool showCook = hasCooking;
    final bool showFlame = hasAttendance && !hasCooking;

    return Center(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: (showCook || showFlame)
              ? const Color(0xFFFFF5EC)
              : backgroundColor,
          gradient: showCook
              ? const RadialGradient(
                  center: Alignment(-0.45, -0.55),
                  radius: 1.05,
                  colors: [
                    Color(0xFFFFF3B0),
                    Color(0xFFFFB34E),
                    Color(0xFFFF6B00),
                    Color(0xFFFF4F00),
                  ],
                  stops: [0.0, 0.42, 0.76, 1.0],
                )
              : showFlame
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFFFFFCF7),
                    Color(0xFFFFE2C4),
                    Color(0xFFFFB777),
                  ],
                )
              : showIce
              ? const RadialGradient(
                  center: Alignment(-0.45, -0.55),
                  radius: 1.05,
                  colors: [
                    Color(0xFFF4FBFF),
                    Color(0xFFCDE9FF),
                    Color(0xFFA3D2FF),
                    Color(0xFF7EBCFF),
                  ],
                  stops: [0.0, 0.42, 0.76, 1.0],
                )
              : null,
          shape: BoxShape.circle,
          border: (showCook || showFlame)
              ? Border.all(color: const Color(0x55FFFFFF), width: 0.8)
              : isToday
              ? Border.all(color: const Color(0xFFFF6B00), width: 1.2)
              : showIce
              ? Border.all(color: const Color(0x66FFFFFF), width: 0.8)
              : Border.all(color: Colors.transparent, width: 1),
          boxShadow: showCook
              ? const [
                  BoxShadow(
                    color: Color(0x52FF6B00),
                    blurRadius: 16,
                    offset: Offset(0, 6),
                    spreadRadius: -1,
                  ),
                  BoxShadow(
                    color: Color(0x38FFD24A),
                    blurRadius: 18,
                    spreadRadius: 1,
                  ),
                ]
              : showFlame
              ? const [
                  BoxShadow(
                    color: Color(0x26FF8A24),
                    blurRadius: 12,
                    offset: Offset(0, 4),
                    spreadRadius: -2,
                  ),
                  BoxShadow(
                    color: Color(0x10000000),
                    blurRadius: 6,
                    offset: Offset(0, 2),
                  ),
                ]
              : showIce
              ? const [
                  BoxShadow(
                    color: Color(0x4044A6FF),
                    blurRadius: 14,
                    offset: Offset(0, 5),
                    spreadRadius: -2,
                  ),
                  BoxShadow(
                    color: Color(0x308FD0FF),
                    blurRadius: 16,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: showCook
            ? Image.asset(
                'assets/icons/streak_cook_3d.png',
                width: 30,
                height: 30,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
              )
            : showFlame
            ? Image.asset(
                'assets/icons/streak_flame_3d.png',
                width: 26,
                height: 26,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
              )
            : showIce
            ? Image.asset(
                'assets/icons/streak_ice_3d.png',
                width: 27,
                height: 27,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
              )
            : Text(
                '${day.day}',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  color: foregroundColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  height: 1,
                ),
                textAlign: TextAlign.center,
              ),
      ),
    );
  }

  DateTime? _firstActivityDay() {
    final keys = <String>{..._effectiveAttendanceDays(), ..._effectiveCookingDays()};
    if (keys.isEmpty) return null;
    final earliest = keys.reduce((a, b) => a.compareTo(b) <= 0 ? a : b);
    final parts = earliest.split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final dayNum = int.tryParse(parts[2]);
    if (year == null || month == null || dayNum == null) return null;
    return DateTime(year, month, dayNum);
  }

  int _currentStreak(Set<String> days) {
    return _userService.currentStreakFromAttendanceDays(days);
  }

  int _countDaysInMonth(Set<String> days, DateTime month) {
    final monthPrefix =
        '${month.year}-${month.month.toString().padLeft(2, '0')}-';
    return days.where((day) => day.startsWith(monthPrefix)).length;
  }

  Set<String> _effectiveAttendanceDays() {
    final days = Set<String>.from(_attendanceDays);
    if (widget.includeTodayAttendance) {
      days.add(_dayKey(DateTime.now()));
    }
    return days;
  }

  Set<String> _effectiveCookingDays() {
    return Set<String>.from(_cookingDays);
  }

  DateTime _startOfDay(DateTime dateTime) =>
      DateTime(dateTime.year, dateTime.month, dateTime.day);

  DateTime _startOfWeek(DateTime dateTime) {
    final day = _startOfDay(dateTime);
    return day.subtract(Duration(days: day.weekday % 7));
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _dayKey(DateTime dateTime) => UserService.streakDayKey(dateTime);
}
