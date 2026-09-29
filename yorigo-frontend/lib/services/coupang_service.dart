import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import '../config/environment_config.dart';

class CoupangProduct {
  final String productId;
  final String productName;
  final int productPrice;
  final String productImage;
  final String productUrl;
  final String? originalUrl;
  final String? deeplinkUrl;
  /// 스크래핑이 넣은 AFFSDP 랜딩. 없으면 단축 URL을 연다.
  final String? landingUrl;
  final double? unitPrice; // Price per unit (g, ml, etc.)
  final double? packageSize; // Size in grams or ml
  final String? packageUnit; // Unit (g, ml, kg, l, etc.)
  final double? matchScore; // How well it matches the need (0-100)
  final bool isRocket; // Rocket delivery available
  final bool isFreeShipping; // Free shipping available
  final String? tag; // Tag for UI display: "최적", "추천", "아주 싼", "대용량", etc.
  final int? salesRank; // Sales rank from API 'rank' field (1-10, lower is better)
  // New fields from scraping
  final int? originalPrice; // Original price before discount
  final double? discountRate; // Discount rate (%)
  final double? rating; // Product rating (0.0 ~ 5.0)
  final int? reviews; // Number of reviews
  final String? arrivalInfo; // Arrival information (e.g., "내일(토) 도착 예정")
  final String? deliveryTextRaw; // Original scraped delivery text (preserved)
  final int? deliveryEtaDays; // Days until delivery from scrape date (for "N일 후 도착")
  final double? volumeG; // Normalized package volume in base unit (g/ml)
  final double? bayesianRating; // Bayesian adjusted rating
  final double? valueScore; // Value score (rating/unit price)

  CoupangProduct({
    required this.productId,
    required this.productName,
    required this.productPrice,
    required this.productImage,
    required this.productUrl,
    this.originalUrl,
    this.deeplinkUrl,
    this.landingUrl,
    this.unitPrice,
    this.packageSize,
    this.packageUnit,
    this.matchScore,
    this.isRocket = false,
    this.isFreeShipping = false,
    this.tag,
    this.salesRank,
    this.originalPrice,
    this.discountRate,
    this.rating,
    this.reviews,
    this.arrivalInfo,
    this.deliveryTextRaw,
    this.deliveryEtaDays,
    this.volumeG,
    this.bayesianRating,
    this.valueScore,
  });

  factory CoupangProduct.fromJson(Map<String, dynamic> json) {
    return CoupangProduct(
      productId: json['product_id']?.toString() ?? '',
      productName: json['product_name']?.toString() ?? '',
      productPrice: json['product_price'] ?? 0,
      productImage: json['product_image']?.toString() ?? '',
      productUrl: json['product_url']?.toString() ?? '',
      originalUrl: json['original_url']?.toString(),
      deeplinkUrl: json['deeplink_url']?.toString(),
      landingUrl: _parseLandingUrl(json),
      unitPrice: json['unit_price']?.toDouble(),
      packageSize: json['package_size']?.toDouble(),
      packageUnit: json['package_unit']?.toString(),
      matchScore: json['match_score']?.toDouble(),
      isRocket: json['is_rocket'] ?? false,
      isFreeShipping: json['is_free_shipping'] ?? false,
      tag: json['tag']?.toString(),
      salesRank: json['sales_rank'] is int
          ? json['sales_rank']
          : (json['sales_rank'] != null
              ? int.tryParse(json['sales_rank'].toString())
              : null),
      // New fields from scraping
      originalPrice: json['original_price'] is int
          ? json['original_price']
          : (json['original_price'] != null
              ? int.tryParse(json['original_price'].toString())
              : null),
      discountRate: json['discount_rate']?.toDouble(),
      rating: json['rating']?.toDouble(),
      reviews: json['reviews'] is int
          ? json['reviews']
          : (json['reviews'] != null
              ? int.tryParse(json['reviews'].toString())
              : null),
      arrivalInfo: json['arrival_info']?.toString(),
      deliveryTextRaw: json['delivery_text_raw']?.toString(),
      deliveryEtaDays: json['delivery_eta_days'] is int
          ? json['delivery_eta_days']
          : (json['delivery_eta_days'] != null
              ? int.tryParse(json['delivery_eta_days'].toString())
              : null),
      volumeG: json['volume_g']?.toDouble(),
      bayesianRating: json['bayesian_rating']?.toDouble(),
      valueScore: json['value_score']?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'product_id': productId,
      'product_name': productName,
      'product_price': productPrice,
      'product_image': productImage,
      'product_url': productUrl,
      'original_url': originalUrl,
      'deeplink_url': deeplinkUrl,
      'landing_url': landingUrl,
      'unit_price': unitPrice,
      'package_size': packageSize,
      'package_unit': packageUnit,
      'match_score': matchScore,
      'is_rocket': isRocket,
      'is_free_shipping': isFreeShipping,
      'tag': tag,
      'sales_rank': salesRank,
      'original_price': originalPrice,
      'discount_rate': discountRate,
      'rating': rating,
      'reviews': reviews,
      'arrival_info': arrivalInfo,
      'delivery_text_raw': deliveryTextRaw,
      'delivery_eta_days': deliveryEtaDays,
      'volume_g': volumeG,
      'bayesian_rating': bayesianRating,
      'value_score': valueScore,
    };
  }

  static String? _parseLandingUrl(Map<String, dynamic> json) {
    for (final key in const <String>['landing_url', 'landingUrl']) {
      final value = json[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  String get formattedPrice {
    return '₩${productPrice.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]},')}';
  }

  String get packageInfo {
    if (packageSize != null && packageUnit != null) {
      return '${packageSize!.toStringAsFixed(0)}$packageUnit';
    }
    return '';
  }
}

class ProductRecommendation {
  final String ingredient;
  final String? displayName;
  final double? neededQty;
  final String? neededUnit;
  final CoupangProduct? bestMatch;
  final List<CoupangProduct> seeMoreList; // See More List (전체 후보) - 더보기 클릭 시 노출
  final List<CoupangProduct> allProducts; // Deprecated: kept for backward compatibility

  String get effectiveDisplayName => displayName ?? ingredient;

  ProductRecommendation({
    required this.ingredient,
    this.displayName,
    this.neededQty,
    this.neededUnit,
    this.bestMatch,
    this.seeMoreList = const [],
    this.allProducts = const [],
  });

  factory ProductRecommendation.fromJson(Map<String, dynamic> json) {
    return ProductRecommendation(
      ingredient: json['ingredient']?.toString() ?? '',
      displayName: json['display_name']?.toString(),
      neededQty: json['needed_qty']?.toDouble(),
      neededUnit: json['needed_unit']?.toString(),
      bestMatch: json['best_match'] != null
          ? CoupangProduct.fromJson(
              Map<String, dynamic>.from(json['best_match'] as Map),
            )
          : null,
      seeMoreList:
          (json['see_more_list'] as List<dynamic>?)
              ?.map((e) => CoupangProduct.fromJson(
                    Map<String, dynamic>.from(e as Map),
                  ))
              .toList() ??
          [],
      allProducts:
          (json['all_products'] as List<dynamic>?)
              ?.map((e) => CoupangProduct.fromJson(
                    Map<String, dynamic>.from(e as Map),
                  ))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'ingredient': ingredient,
      'display_name': displayName,
      'needed_qty': neededQty,
      'needed_unit': neededUnit,
      'best_match': bestMatch?.toJson(),
      'see_more_list': seeMoreList.map((p) => p.toJson()).toList(),
      'all_products': allProducts.map((p) => p.toJson()).toList(),
    };
  }
}

class ProductSearchResult {
  final String productId;
  final String productName;
  final int productPrice;
  final String productImage;
  final String productUrl;
  final double? packageSize;
  final String? packageUnit;
  final double? unitPrice;
  final double? amountMatchScore;
  final double? totalMatchScore;

  ProductSearchResult({
    required this.productId,
    required this.productName,
    required this.productPrice,
    required this.productImage,
    required this.productUrl,
    this.packageSize,
    this.packageUnit,
    this.unitPrice,
    this.amountMatchScore,
    this.totalMatchScore,
  });

  factory ProductSearchResult.fromJson(Map<String, dynamic> json) {
    return ProductSearchResult(
      productId: json['product_id']?.toString() ?? '',
      productName: json['product_name']?.toString() ?? '',
      productPrice: json['product_price'] ?? 0,
      productImage: json['product_image']?.toString() ?? '',
      productUrl: json['product_url']?.toString() ?? '',
      packageSize: json['package_size']?.toDouble(),
      packageUnit: json['package_unit']?.toString(),
      unitPrice: json['unit_price']?.toDouble(),
      amountMatchScore: json['amount_match_score']?.toDouble(),
      totalMatchScore: json['total_match_score']?.toDouble(),
    );
  }

  String get formattedPrice {
    return '₩${productPrice.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]},')}';
  }

  String get packageInfo {
    if (packageSize != null && packageUnit != null) {
      return '${packageSize!.toStringAsFixed(0)}$packageUnit';
    }
    return '';
  }
}

class AdvancedProductSearchResponse {
  final String ingredient;
  final double? neededQty;
  final String? neededUnit;
  final ProductSearchResult? bestAmountMatch;
  final ProductSearchResult? cheapestSameAmount;
  final ProductSearchResult? cheapestOverall;
  final List<ProductSearchResult> allProducts;

  AdvancedProductSearchResponse({
    required this.ingredient,
    this.neededQty,
    this.neededUnit,
    this.bestAmountMatch,
    this.cheapestSameAmount,
    this.cheapestOverall,
    this.allProducts = const [],
  });

  factory AdvancedProductSearchResponse.fromJson(Map<String, dynamic> json) {
    return AdvancedProductSearchResponse(
      ingredient: json['ingredient']?.toString() ?? '',
      neededQty: json['needed_qty']?.toDouble(),
      neededUnit: json['needed_unit']?.toString(),
      bestAmountMatch: json['best_amount_match'] != null
          ? ProductSearchResult.fromJson(json['best_amount_match'])
          : null,
      cheapestSameAmount: json['cheapest_same_amount'] != null
          ? ProductSearchResult.fromJson(json['cheapest_same_amount'])
          : null,
      cheapestOverall: json['cheapest_overall'] != null
          ? ProductSearchResult.fromJson(json['cheapest_overall'])
          : null,
      allProducts:
          (json['all_products'] as List<dynamic>?)
              ?.map((e) => ProductSearchResult.fromJson(e))
              .toList() ??
          [],
    );
  }
}

class CoupangService {
  // Backend URL is automatically determined based on environment
  static String get baseUrl => EnvironmentConfig.baseUrl;

  /// Preprocess ingredients using LLM to simplify them for better search results
  /// Example: "계란 노른자" → "계란"
  Future<Map<String, String>> preprocessIngredients(
    List<String> ingredients,
  ) async {
    final sw = Stopwatch()..start();
    try {
      // DEBUG: Log preprocessing call
      print('[CoupangService] preprocessIngredients() called');
      print('[CoupangService]   - Ingredients: $ingredients');
      print('[CoupangService]   - This will call /preprocess_ingredients (no Coupang API)');
      
      final uri = Uri.parse('$baseUrl/preprocess_ingredients');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'ingredients': ingredients}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final preprocessed = Map<String, String>.from(data['preprocessed']);

        print(
          '[CoupangService] Preprocessed ${preprocessed.length} ingredients',
        );
        for (final entry in preprocessed.entries) {
          if (entry.key != entry.value) {
            print('[CoupangService]   "${entry.key}" → "${entry.value}"');
          }
        }
        print(
          '[PERF][preprocess] n=${ingredients.length} '
          'http_ms=${sw.elapsedMilliseconds} status=200',
        );

        return preprocessed;
      } else {
        print('Error preprocessing ingredients: ${response.statusCode}');
        print(
          '[PERF][preprocess] n=${ingredients.length} '
          'http_ms=${sw.elapsedMilliseconds} status=${response.statusCode}',
        );
        // Fallback: return identity map
        return {for (var ing in ingredients) ing: ing};
      }
    } catch (e) {
      print('Exception in preprocessIngredients: $e');
      print(
        '[PERF][preprocess] n=${ingredients.length} '
        'http_ms=${sw.elapsedMilliseconds} error=$e',
      );
      // Fallback: return identity map
      return {for (var ing in ingredients) ing: ing};
    }
  }

  /// Advanced product search with 50 results and detailed mapping
  /// Automatically preprocesses ingredient name for better search results
  Future<AdvancedProductSearchResponse?> searchProductsAdvanced({
    required String ingredientName,
    double? neededQty,
    String? neededUnit,
    int limit = 50,
  }) async {
    try {
      // Preprocess ingredient name for better search results
      final preprocessed = await preprocessIngredients([ingredientName]);
      final searchTerm = preprocessed[ingredientName] ?? ingredientName;

      if (kDebugMode && searchTerm != ingredientName) {
        print('[CoupangService] Searching for "$searchTerm" instead of "$ingredientName"');
      }

      final uri = Uri.parse('$baseUrl/search_products_advanced');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'ingredient_name': searchTerm,
          'needed_qty': neededQty,
          'needed_unit': neededUnit,
          'limit': limit,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return AdvancedProductSearchResponse.fromJson(data);
      } else {
        if (kDebugMode) {
          print('Error fetching advanced product search: ${response.statusCode}');
          print('Response body: ${response.body}');
        }
        return null;
      }
    } catch (e) {
      if (kDebugMode) {
        print('Exception in searchProductsAdvanced: $e');
      }
      return null;
    }
  }

  /// Search for products and get recommendations based on ingredient needs
  /// Automatically preprocesses ingredient name for better search results
  /// [marketplace]: "coupang" | "kurly" — Kurly uses Firestore kurly_products.
  Future<ProductRecommendation?> getProductRecommendations({
    required String ingredientName,
    double? neededQty,
    String? neededUnit,
    int limit = 10,
    String marketplace = 'coupang',
  }) async {
    try {
      if (kDebugMode) {
        print('[CoupangService] getProductRecommendations() called');
        print('[CoupangService]   - ingredientName: $ingredientName, marketplace: $marketplace');
        print('[CoupangService]   - neededQty: $neededQty, neededUnit: $neededUnit');
        print('[CoupangService]   - This will call /recommend_products → Firestore cache lookup');
      }

      final useKurly = marketplace.toLowerCase() == 'kurly';
      final searchTerm = useKurly
          ? ingredientName
          : (await preprocessIngredients([ingredientName]))[ingredientName] ?? ingredientName;

      if (kDebugMode && searchTerm != ingredientName && !useKurly) {
        print('[CoupangService] Searching for "$searchTerm" instead of "$ingredientName"');
      }
      final uri = Uri.parse('$baseUrl/recommend_products');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'ingredient_name': searchTerm,
          'original_ingredient_name': ingredientName,
          'needed_qty': neededQty,
          'needed_unit': neededUnit,
          'limit': limit,
          'marketplace': useKurly ? 'kurly' : 'coupang',
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (kDebugMode) {
          print('[CoupangService] Successfully received recommendation for: $ingredientName');
        }
        return ProductRecommendation.fromJson(data);
      } else {
        if (kDebugMode) {
          print('[CoupangService] Error fetching product recommendations: ${response.statusCode}');
          print('[CoupangService] Response body: ${response.body}');
        }
        return null;
      }
    } catch (e) {
      if (kDebugMode) {
        print('Exception in getProductRecommendations: $e');
      }
      return null;
    }
  }

  /// Same as [getProductRecommendations] but assumes the caller has already
  /// resolved the preprocessed search term (e.g. via a batched
  /// [preprocessIngredients] call), skipping the per-call Gemini round-trip.
  Future<ProductRecommendation?> getProductRecommendationsPreprocessed({
    required String searchTerm,
    required String originalIngredientName,
    double? neededQty,
    String? neededUnit,
    int limit = 10,
    String marketplace = 'coupang',
  }) async {
    try {
      final useKurly = marketplace.toLowerCase() == 'kurly';
      if (kDebugMode) {
        print('[CoupangService] getProductRecommendationsPreprocessed() called');
        print(
          '[CoupangService]   - originalIngredientName: $originalIngredientName, searchTerm: $searchTerm, marketplace: $marketplace',
        );
      }

      final uri = Uri.parse('$baseUrl/recommend_products');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'ingredient_name': searchTerm,
          'original_ingredient_name': originalIngredientName,
          'needed_qty': neededQty,
          'needed_unit': neededUnit,
          'limit': limit,
          'marketplace': useKurly ? 'kurly' : 'coupang',
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return ProductRecommendation.fromJson(data);
      } else {
        if (kDebugMode) {
          print(
            '[CoupangService] Error fetching product recommendations (preprocessed): ${response.statusCode}',
          );
        }
        return null;
      }
    } catch (e) {
      if (kDebugMode) {
        print('Exception in getProductRecommendationsPreprocessed: $e');
      }
      return null;
    }
  }

  /// Batch fetch recommendations for multiple ingredients in **one** HTTP call.
  /// Items can mix marketplaces (coupang/kurly). Returns the same response shape
  /// per item, in the same order as [items]. Falls back to null on transport errors.
  Future<List<ProductRecommendation?>?> getProductRecommendationsBatch({
    required List<Map<String, dynamic>> items,
  }) async {
    if (items.isEmpty) return <ProductRecommendation?>[];
    final sw = Stopwatch()..start();
    final marketCounts = <String, int>{};
    for (final it in items) {
      final mp = (it['marketplace'] ?? 'coupang').toString();
      marketCounts[mp] = (marketCounts[mp] ?? 0) + 1;
    }
    try {
      final uri = Uri.parse('$baseUrl/recommend_products_batch');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'items': items}),
      );
      final httpMs = sw.elapsedMilliseconds;
      if (response.statusCode != 200) {
        if (kDebugMode) {
          print(
            '[CoupangService] recommend_products_batch failed: ${response.statusCode} ${response.body}',
          );
        }
        print(
          '[PERF][recommend_batch] n=${items.length} markets=$marketCounts '
          'http_ms=$httpMs status=${response.statusCode} body_bytes=${response.bodyBytes.length}',
        );
        return null;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final raw = (data['items'] as List<dynamic>? ?? const []);
      final results = raw
          .map<ProductRecommendation?>((e) {
            if (e == null) return null;
            try {
              return ProductRecommendation.fromJson(
                Map<String, dynamic>.from(e as Map),
              );
            } catch (err) {
              if (kDebugMode) {
                print('[CoupangService] batch item parse error: $err');
              }
              return null;
            }
          })
          .toList(growable: false);
      final withBest =
          results.where((r) => r?.bestMatch != null).length;
      print(
        '[PERF][recommend_batch] n=${items.length} markets=$marketCounts '
        'http_ms=$httpMs parse_ms=${sw.elapsedMilliseconds - httpMs} '
        'total_ms=${sw.elapsedMilliseconds} status=200 '
        'body_bytes=${response.bodyBytes.length} best_match=$withBest/${results.length}',
      );
      return results;
    } catch (e) {
      if (kDebugMode) {
        print('[CoupangService] recommend_products_batch exception: $e');
      }
      print(
        '[PERF][recommend_batch] n=${items.length} markets=$marketCounts '
        'http_ms=${sw.elapsedMilliseconds} error=$e',
      );
      return null;
    }
  }

  /// Streams recommendations for multiple ingredients over a **single** HTTP
  /// connection (NDJSON), emitting each item the moment the backend finishes
  /// it — instead of waiting for the entire batch like
  /// [getProductRecommendationsBatch]. Each event is `(original index in
  /// [items], result-or-null)`; callers match on index to update UI
  /// incrementally. On transport failure the stream simply ends early —
  /// callers should treat any index never emitted as failed.
  Stream<MapEntry<int, ProductRecommendation?>> getProductRecommendationsStream({
    required List<Map<String, dynamic>> items,
  }) async* {
    if (items.isEmpty) return;
    final sw = Stopwatch()..start();
    final client = http.Client();
    var emitted = 0;
    try {
      final request = http.Request(
        'POST',
        Uri.parse('$baseUrl/recommend_products_stream'),
      )
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode({'items': items});

      final streamed = await client.send(request);
      if (streamed.statusCode != 200) {
        final body = await streamed.stream.bytesToString();
        if (kDebugMode) {
          print(
            '[CoupangService] recommend_products_stream failed: '
            '${streamed.statusCode} $body',
          );
        }
        print(
          '[PERF][recommend_stream] n=${items.length} '
          'http_ms=${sw.elapsedMilliseconds} status=${streamed.statusCode}',
        );
        return;
      }

      final lines = streamed.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final obj = jsonDecode(line) as Map<String, dynamic>;
          final idx = obj['index'] as int;
          final resultJson = obj['result'] as Map<String, dynamic>?;
          final result = resultJson != null
              ? ProductRecommendation.fromJson(resultJson)
              : null;
          emitted++;
          yield MapEntry(idx, result);
        } catch (e) {
          if (kDebugMode) {
            print('[CoupangService] stream line parse error: $e');
          }
        }
      }
      print(
        '[PERF][recommend_stream] n=${items.length} emitted=$emitted '
        'total_ms=${sw.elapsedMilliseconds} status=200',
      );
    } catch (e) {
      if (kDebugMode) {
        print('[CoupangService] recommend_products_stream exception: $e');
      }
      print(
        '[PERF][recommend_stream] n=${items.length} emitted=$emitted '
        'total_ms=${sw.elapsedMilliseconds} error=$e',
      );
    } finally {
      client.close();
    }
  }

  /// Batch get recommendations for multiple ingredients
  Future<Map<String, ProductRecommendation>> getMultipleRecommendations({
    required List<Map<String, dynamic>> ingredients,
  }) async {
    final Map<String, ProductRecommendation> results = {};

    // Process sequentially to respect API rate limits
    for (final ingredient in ingredients) {
      final name =
          ingredient['name']?.toString() ??
          ingredient['item']?.toString() ??
          '';
      if (name.isEmpty) continue;

      final rawQty = ingredient['qty'];
      final qty = rawQty is num ? rawQty.toDouble() : (rawQty is String ? double.tryParse(rawQty) : null);
      final unit = ingredient['unit']?.toString();

      final recommendation = await getProductRecommendations(
        ingredientName: name,
        neededQty: qty,
        neededUnit: unit,
      );

      if (recommendation != null) {
        results[name] = recommendation;
      }

      // Small delay to avoid rate limiting (Coupang API allows 10 calls per hour)
      await Future.delayed(const Duration(milliseconds: 500));
    }

    return results;
  }

  Future<bool> excludeProductGloballyForAdmin({
    required String productId,
    String? reason,
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return false;
      final token = await user.getIdToken();
      final uri = Uri.parse('$baseUrl/admin/excluded-products');
      final response = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'product_id': productId,
          'reason': reason,
        }),
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return true;
      }
      if (kDebugMode) {
        print('[CoupangService] excludeProductGloballyForAdmin failed: ${response.statusCode} ${response.body}');
      }
      return false;
    } catch (e) {
      if (kDebugMode) {
        print('[CoupangService] excludeProductGloballyForAdmin exception: $e');
      }
      return false;
    }
  }

  /// Live marketplace search for meal kits. Skips ingredient preprocessing
  /// so queries like "된장찌개 밀키트" are sent as-is.
  Future<List<CoupangProduct>> searchMealKitProducts(
    String query, {
    String marketplace = 'coupang',
  }) async {
    try {
      if (marketplace.toLowerCase() == 'kurly') {
        final rec = await getProductRecommendations(
          ingredientName: query,
          limit: 20,
          marketplace: 'kurly',
        );
        return _productsFromRecommendation(rec);
      }

      final uri = Uri.parse('$baseUrl/search_products_advanced');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'ingredient_name': query,
          'limit': 30,
        }),
      );
      if (response.statusCode != 200) {
        final rec = await getProductRecommendations(
          ingredientName: query,
          limit: 20,
          marketplace: 'coupang',
        );
        return _productsFromRecommendation(rec);
      }

      final data = jsonDecode(response.body);
      if (data is! Map) return const [];
      final seen = <String>{};
      final out = <CoupangProduct>[];

      void add(dynamic raw) {
        if (raw is! Map) return;
        final p = CoupangProduct.fromJson(Map<String, dynamic>.from(raw));
        if (p.productId.isEmpty || p.productName.isEmpty) return;
        if (!seen.add(p.productId)) return;
        out.add(p);
      }

      add(data['best_amount_match']);
      add(data['cheapest_overall']);
      add(data['cheapest_same_amount']);
      final all = data['all_products'];
      if (all is List) {
        for (final item in all) {
          add(item);
        }
      }
      return out;
    } catch (e) {
      if (kDebugMode) {
        print('[CoupangService] searchMealKitProducts: $e');
      }
      return const [];
    }
  }

  List<CoupangProduct> _productsFromRecommendation(ProductRecommendation? rec) {
    if (rec == null) return const [];
    final out = <CoupangProduct>[];
    final seen = <String>{};
    if (rec.bestMatch != null &&
        rec.bestMatch!.productId.isNotEmpty &&
        seen.add(rec.bestMatch!.productId)) {
      out.add(rec.bestMatch!);
    }
    for (final p in rec.seeMoreList) {
      if (p.productId.isEmpty || !seen.add(p.productId)) continue;
      out.add(p);
    }
    return out;
  }
}
