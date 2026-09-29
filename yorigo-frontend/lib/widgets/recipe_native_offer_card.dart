import 'dart:async';

import 'package:flutter/material.dart';

import '../screens/cart_screen.dart' show openMarketplaceLink, ShoppingMarketplace;
import '../services/coupang_service.dart';
import '../services/user_service.dart';
import '../utils/coupang_subparam.dart';
import 'app_network_image.dart';

class RecipeNativeOfferCard extends StatelessWidget {
  const RecipeNativeOfferCard({
    super.key,
    required this.product,
    required this.sourceScreen,
    this.ingredientName,
    this.recipeId,
  });

  final CoupangProduct product;
  final String sourceScreen;
  final String? ingredientName;
  final String? recipeId;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: () => _open(context),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE8E6E3), width: 0.8),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0F000000),
                blurRadius: 8,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 58,
                  height: 58,
                  child: product.productImage.isNotEmpty
                      ? AppNetworkImage(
                          imageUrl: product.productImage,
                          width: 58,
                          height: 58,
                          fit: BoxFit.cover,
                          memCacheWidth: AppNetworkImage.avatarCacheSize,
                          memCacheHeight: AppNetworkImage.avatarCacheSize,
                        )
                      : const ColoredBox(
                          color: Color(0xFFF3F4F6),
                          child: Icon(
                            Icons.image_outlined,
                            size: 22,
                            color: Color(0xFFB0A89F),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      product.productName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF111111),
                        height: 1.25,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${_formatPrice(product.productPrice)}원',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF111111),
                              height: 1,
                              letterSpacing: -0.3,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () => _open(context),
                          child: Container(
                            height: 30,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: const Color(0xFF16A34A),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Text(
                              '보러가기',
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                                height: 1,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final subparam = await UserService().getCurrentCoupangSubparam();
    final args = coupangMarketplaceLinkArgs(
      landingUrl: product.landingUrl,
      deeplinkUrl: product.deeplinkUrl,
      productUrl: product.productUrl,
      originalUrl: product.originalUrl,
      subparam: subparam,
    );
    if (!context.mounted) return;
    unawaited(
      UserService().logAffiliateVisit(
        marketplace: 'coupang',
        sourceScreen: sourceScreen,
        productId: product.productId,
        ingredientName: ingredientName,
      ),
    );
    await openMarketplaceLink(
      context,
      deepLinkUrl: args.deepLinkUrl,
      httpsUrl: args.httpsUrl,
      marketplace: ShoppingMarketplace.coupang,
      ingredientName: ingredientName,
      recipeId: recipeId,
      productId: product.productId,
      sourceScreen: sourceScreen,
    );
  }

  static String _formatPrice(int price) {
    return price.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (Match m) => '${m[1]},',
    );
  }
}
