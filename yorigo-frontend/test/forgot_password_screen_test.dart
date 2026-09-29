import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/screens/forgot_password_screen.dart';

void main() {
  group('ForgotPasswordScreen', () {
    testWidgets('shows validation error for invalid email', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ForgotPasswordScreen(
            onRequestReset: (_) async {},
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'not-an-email');
      await tester.tap(find.text('재설정 링크 보내기'));
      await tester.pump();

      expect(find.text('올바른 이메일을 입력해주세요.'), findsOneWidget);
    });

    testWidgets('shows success state after reset request', (tester) async {
      var requestedEmail = '';

      await tester.pumpWidget(
        MaterialApp(
          home: ForgotPasswordScreen(
            onRequestReset: (email) async {
              requestedEmail = email;
            },
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'user@example.com');
      await tester.tap(find.text('재설정 링크 보내기'));
      await tester.pumpAndSettle();

      expect(requestedEmail, 'user@example.com');
      expect(find.text('재설정 링크를 보냈습니다'), findsOneWidget);
      expect(find.text('로그인으로 돌아가기'), findsOneWidget);
    });

    testWidgets('prefills initial email', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ForgotPasswordScreen(
            initialEmail: 'prefill@test.com',
            onRequestReset: (_) async {},
          ),
        ),
      );

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller?.text, 'prefill@test.com');
    });
  });
}
