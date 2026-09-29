import 'package:flutter/material.dart';

import '../services/admin_service.dart';
import '../services/rewards_service.dart';
import '../theme/app_colors.dart';
import '../widgets/app_refresh_indicator.dart';

/// 관리자: 구매완료 사진인증(온라인 주문확인) 수동 검수 큐.
class AdminPurchaseVerificationScreen extends StatefulWidget {
  const AdminPurchaseVerificationScreen({super.key});

  @override
  State<AdminPurchaseVerificationScreen> createState() =>
      _AdminPurchaseVerificationScreenState();
}

class _AdminPurchaseVerificationScreenState
    extends State<AdminPurchaseVerificationScreen> {
  bool _checkingAdmin = true;
  bool _isAdmin = false;
  bool _loading = true;
  bool _reviewingIdBusy = false;
  String? _busyVerificationId;
  List<PurchaseVerificationQueueItem> _items =
      const <PurchaseVerificationQueueItem>[];

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final isAdmin = await AdminService.instance.isAdmin();
    if (!mounted) return;
    setState(() {
      _isAdmin = isAdmin;
      _checkingAdmin = false;
    });
    if (!isAdmin) return;
    await _loadQueue();
  }

  Future<void> _loadQueue() async {
    if (!mounted) return;
    setState(() => _loading = true);
    final items =
        await RewardsService.instance.fetchPurchaseVerificationQueue();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  Future<void> _review(PurchaseVerificationQueueItem item, bool approve) async {
    if (_reviewingIdBusy) return;
    setState(() {
      _reviewingIdBusy = true;
      _busyVerificationId = item.id;
    });
    final result = await RewardsService.instance.reviewPurchaseVerification(
      verificationId: item.id,
      approve: approve,
    );
    if (!mounted) return;
    setState(() {
      _reviewingIdBusy = false;
      _busyVerificationId = null;
    });
    if (result == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('처리에 실패했어요. 잠시 후 다시 시도해주세요.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    setState(() {
      _items = _items.where((e) => e.id != item.id).toList();
    });
    final msg = approve
        ? '승인 완료 (+${result.pointsAwarded}P)'
        : '거절 처리됐어요';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: approve ? const Color(0xFFFF6B00) : Colors.grey,
      ),
    );
  }

  String _marketplaceLabel(String? raw) {
    switch ((raw ?? '').toLowerCase()) {
      case 'coupang':
        return '쿠팡';
      case 'kurly':
      case 'market_kurly':
      case 'marketkurly':
        return '컬리';
      default:
        return (raw == null || raw.isEmpty) ? '미상' : raw;
    }
  }

  String _formatAmount(int? amount) {
    if (amount == null) return '-';
    final s = amount.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final fromEnd = s.length - i;
      buf.write(s[i]);
      if (fromEnd > 1 && fromEnd % 3 == 1) buf.write(',');
    }
    return '${buf}원';
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Scaffold(
      backgroundColor: AppColors.getBackground(brightness),
      appBar: AppBar(
        title: const Text(
          '구매인증 검수',
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontWeight: FontWeight.w700,
          ),
        ),
        backgroundColor: AppColors.getBackground(brightness),
        foregroundColor: AppColors.getTextPrimary(brightness),
        elevation: 0,
      ),
      body: _checkingAdmin
          ? const Center(child: CircularProgressIndicator())
          : !_isAdmin
              ? const Center(
                  child: Text(
                    '관리자만 접근할 수 있어요',
                    style: TextStyle(fontFamily: 'Pretendard'),
                  ),
                )
              : AppRefreshIndicator(
                  onRefresh: _loadQueue,
                  child: _loading
                      ? ListView(
                          children: const [
                            SizedBox(height: 120),
                            Center(child: CircularProgressIndicator()),
                          ],
                        )
                      : _items.isEmpty
                          ? ListView(
                              children: const [
                                SizedBox(height: 120),
                                Center(
                                  child: Text(
                                    '대기 중인 인증이 없어요',
                                    style: TextStyle(
                                      fontFamily: 'Pretendard',
                                      color: Color(0xFF6A7282),
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                              itemCount: _items.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 10),
                              itemBuilder: (context, index) {
                                final item = _items[index];
                                final busy = _busyVerificationId == item.id;
                                return Container(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    14,
                                    16,
                                    12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: const Color(0xFFF3F4F6),
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(
                                          alpha: 0.05,
                                        ),
                                        blurRadius: 10,
                                        offset: const Offset(0, 3),
                                      ),
                                    ],
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 3,
                                            ),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFFFF1E6),
                                              borderRadius:
                                                  BorderRadius.circular(100),
                                            ),
                                            child: Text(
                                              _marketplaceLabel(
                                                item.marketplace,
                                              ),
                                              style: const TextStyle(
                                                fontFamily: 'Pretendard',
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                                color: Color(0xFFFF6B00),
                                              ),
                                            ),
                                          ),
                                          const Spacer(),
                                          Text(
                                            item.confidence == null
                                                ? 'conf -'
                                                : 'conf ${(item.confidence! * 100).round()}%',
                                            style: const TextStyle(
                                              fontFamily: 'Pretendard',
                                              fontSize: 11,
                                              color: Color(0xFF6A7282),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 10),
                                      Text(
                                        '주문번호: ${item.orderNumber?.isNotEmpty == true ? item.orderNumber : '-'}',
                                        style: const TextStyle(
                                          fontFamily: 'Pretendard',
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '결제금액: ${_formatAmount(item.extractedAmount)}',
                                        style: const TextStyle(
                                          fontFamily: 'Pretendard',
                                          fontSize: 13,
                                          color: Color(0xFF374151),
                                        ),
                                      ),
                                      if (item.purchasedAtRaw != null &&
                                          item.purchasedAtRaw!.isNotEmpty) ...[
                                        const SizedBox(height: 2),
                                        Text(
                                          '구매일시: ${item.purchasedAtRaw}',
                                          style: const TextStyle(
                                            fontFamily: 'Pretendard',
                                            fontSize: 12,
                                            color: Color(0xFF6A7282),
                                          ),
                                        ),
                                      ],
                                      const SizedBox(height: 2),
                                      Text(
                                        'uid: ${item.uid}',
                                        style: const TextStyle(
                                          fontFamily: 'Pretendard',
                                          fontSize: 11,
                                          color: Color(0xFF9CA3AF),
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      if (item.createdAt != null) ...[
                                        const SizedBox(height: 2),
                                        Text(
                                          '제출: ${item.createdAt}',
                                          style: const TextStyle(
                                            fontFamily: 'Pretendard',
                                            fontSize: 11,
                                            color: Color(0xFF9CA3AF),
                                          ),
                                        ),
                                      ],
                                      const SizedBox(height: 12),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: OutlinedButton(
                                              onPressed: busy
                                                  ? null
                                                  : () => _review(item, false),
                                              child: busy
                                                  ? const SizedBox(
                                                      width: 16,
                                                      height: 16,
                                                      child:
                                                          CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                      ),
                                                    )
                                                  : const Text('거절'),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: ElevatedButton(
                                              onPressed: busy
                                                  ? null
                                                  : () => _review(item, true),
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor:
                                                    const Color(0xFFFF6B00),
                                                foregroundColor: Colors.white,
                                              ),
                                              child: const Text('승인 (+1500P)'),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                ),
    );
  }
}
