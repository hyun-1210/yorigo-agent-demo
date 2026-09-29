/// Example usage of EnvironmentConfig
/// This file demonstrates various ways to use the environment configuration
/// You can delete this file - it's just for reference
library;

import 'package:flutter/foundation.dart';
import 'environment_config.dart';

void environmentConfigExamples() {
  // ============================================
  // Example 1: Get current environment info
  // ============================================
  print('Current Environment: ${EnvironmentConfig.currentEnvironment}');
  print('Backend URL: ${EnvironmentConfig.baseUrl}');

  // ============================================
  // Example 2: Print full configuration
  // ============================================
  EnvironmentConfig.printConfig();
  // Output:
  // === Environment Configuration ===
  // Environment: Environment.local
  // Backend URL: http://localhost:8000
  // Debug Mode: true
  // Release Mode: false
  // Platform: TargetPlatform.macOS
  // Manual Override: None
  // ================================

  // ============================================
  // Example 3: Manually switch environment
  // ============================================

  // Switch to production (e.g., to test production API in debug mode)
  EnvironmentConfig.setEnvironment(Environment.production);
  print('Switched to: ${EnvironmentConfig.baseUrl}');
  // Output: https://yorigo-production.up.railway.app

  // Switch to local
  EnvironmentConfig.setEnvironment(Environment.local);
  print('Switched to: ${EnvironmentConfig.baseUrl}');
  // Output: http://localhost:8000

  // Switch to mobile testing
  EnvironmentConfig.setEnvironment(Environment.mobileTesting);
  print('Switched to: ${EnvironmentConfig.baseUrl}');
  // Output: http://192.168.1.100:8000

  // Reset to automatic detection
  EnvironmentConfig.resetEnvironment();
  print('Reset to automatic: ${EnvironmentConfig.baseUrl}');

  // ============================================
  // Example 4: Custom URL for mobile testing
  // ============================================

  // Use ngrok URL
  EnvironmentConfig.setMobileTestingUrl('https://abc123.ngrok.io');
  EnvironmentConfig.setEnvironment(Environment.mobileTesting);
  print('Using custom URL: ${EnvironmentConfig.baseUrl}');
  // Output: https://abc123.ngrok.io

  // Use local network IP
  EnvironmentConfig.setMobileTestingUrl('http://192.168.1.50:8000');
  EnvironmentConfig.setEnvironment(Environment.mobileTesting);
  print('Using local IP: ${EnvironmentConfig.baseUrl}');
  // Output: http://192.168.1.50:8000

  // ============================================
  // Example 5: Conditional logic based on environment
  // ============================================

  if (EnvironmentConfig.currentEnvironment == Environment.production) {
    print('Running in production - enable analytics');
  } else {
    print('Running in dev/test - disable analytics');
  }

  // ============================================
  // Example 6: Use in API calls
  // ============================================

  // The services automatically use EnvironmentConfig.baseUrl
  // Here's how it works internally:

  final apiEndpoint = '${EnvironmentConfig.baseUrl}/parse_recipe';
  print('API Endpoint: $apiEndpoint');
  // Output depends on environment:
  // - Local: http://localhost:8000/parse_recipe
  // - Mobile: http://192.168.1.100:8000/parse_recipe
  // - Production: https://yorigo-production.up.railway.app/parse_recipe

  // ============================================
  // Example 7: Debug-only environment override
  // ============================================

  if (kDebugMode) {
    // Only in debug mode, you can override
    print('Debug mode - can override environment');
    EnvironmentConfig.setEnvironment(Environment.local);
  } else {
    // In release mode, this won't execute
    print('Release mode - always uses production');
  }
}

/// Example: Testing different scenarios
void testScenarios() {
  print('\n=== Testing Different Scenarios ===\n');

  // Scenario 1: Local development on web
  print('Scenario 1: Web development');
  print('Platform: $defaultTargetPlatform');
  print('Debug Mode: $kDebugMode');
  if (kDebugMode && kIsWeb) {
    print('Expected: Environment.local (http://localhost:8000)');
  }
  print(
    'Actual: ${EnvironmentConfig.currentEnvironment} (${EnvironmentConfig.baseUrl})',
  );

  print('\n---\n');

  // Scenario 2: iOS simulator
  print('Scenario 2: iOS Simulator');
  print('Platform: $defaultTargetPlatform');
  print('Debug Mode: $kDebugMode');
  if (kDebugMode && defaultTargetPlatform == TargetPlatform.iOS) {
    print('Note: Simulator uses local, physical device uses mobile testing');
  }
  print(
    'Actual: ${EnvironmentConfig.currentEnvironment} (${EnvironmentConfig.baseUrl})',
  );

  print('\n---\n');

  // Scenario 3: Production build
  print('Scenario 3: Production Build');
  print('Release Mode: $kReleaseMode');
  if (kReleaseMode) {
    print('Expected: Environment.production');
  }
  print(
    'Actual: ${EnvironmentConfig.currentEnvironment} (${EnvironmentConfig.baseUrl})',
  );
}

/// Example: Custom environment for specific testing
class CustomEnvironmentSetup {
  static void setupForTesting() {
    // Use this at the start of your tests
    EnvironmentConfig.setEnvironment(Environment.local);
  }

  static void setupForMobileDemo() {
    // Use this when demoing on a device
    EnvironmentConfig.setMobileTestingUrl('https://demo.ngrok.io');
    EnvironmentConfig.setEnvironment(Environment.mobileTesting);
  }

  static void setupForStaging() {
    // If you have a staging server
    EnvironmentConfig.setMobileTestingUrl(
      'https://yorigo-staging.up.railway.app',
    );
    EnvironmentConfig.setEnvironment(Environment.mobileTesting);
  }

  static void reset() {
    EnvironmentConfig.resetEnvironment();
  }
}

/// Example: Widget that shows current environment
/// (Already implemented in environment_switcher.dart)
/// This is just a simple text widget example
class EnvironmentBadge {
  static String getText() {
    switch (EnvironmentConfig.currentEnvironment) {
      case Environment.local:
        return '🟢 Local Development';
      case Environment.mobileTesting:
        return '🟡 Mobile Testing';
      case Environment.production:
        return '🔴 Production';
    }
  }

  static bool shouldShow() {
    // Only show badge in non-production environments
    return EnvironmentConfig.currentEnvironment != Environment.production;
  }
}
