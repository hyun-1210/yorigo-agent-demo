import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/auth_service.dart';

class PassVerificationWebviewResult {
  const PassVerificationWebviewResult({
    required this.verified,
    this.verificationToken,
    this.reason,
    this.message,
  });

  final bool verified;
  final String? verificationToken;
  final String? reason;
  final String? message;
}

class PassVerificationWebviewScreen extends StatefulWidget {
  const PassVerificationWebviewScreen({super.key, required this.initResult});

  final NicePassInitResult initResult;

  @override
  State<PassVerificationWebviewScreen> createState() =>
      _PassVerificationWebviewScreenState();
}

class _PassVerificationWebviewScreenState
    extends State<PassVerificationWebviewScreen> {
  late final WebViewController _controller;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (!mounted) return;
            setState(() {
              _progress = progress / 100;
            });
          },
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri != null &&
                uri.scheme == 'yorigo' &&
                (uri.host == 'pass-callback' ||
                    uri.host == 'sms-callback' ||
                    uri.host == 'identity-callback')) {
              final verified = uri.queryParameters['verified'] == 'true';
              final token = uri.queryParameters['verification_token'];
              final reason = uri.queryParameters['reason'];
              final message = uri.queryParameters['message'];
              Navigator.of(context).pop(
                PassVerificationWebviewResult(
                  verified: verified,
                  verificationToken: token,
                  reason: reason,
                  message: message,
                ),
              );
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadHtmlString(_buildAutoSubmitHtml(widget.initResult));
  }

  String _buildAutoSubmitHtml(NicePassInitResult initResult) {
    final action = htmlEscape.convert(initResult.authActionUrl);
    final tokenVersionId = htmlEscape.convert(initResult.tokenVersionId);
    final encData = htmlEscape.convert(initResult.encData);
    final integrityValue = htmlEscape.convert(initResult.integrityValue);
    return '''
<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>NICE PASS</title>
  </head>
  <body onload="document.getElementById('niceForm').submit();">
    <p>본인인증 창으로 이동 중입니다...</p>
    <form id="niceForm" method="post" action="$action">
      <input type="hidden" name="m" value="service" />
      <input type="hidden" name="token_version_id" value="$tokenVersionId" />
      <input type="hidden" name="enc_data" value="$encData" />
      <input type="hidden" name="integrity_value" value="$integrityValue" />
    </form>
  </body>
</html>
''';
  }

  @override
  Widget build(BuildContext context) {
    final verificationLabel =
        widget.initResult.verificationMethod == 'sms' ? 'SMS' : 'PASS';
    return Scaffold(
      appBar: AppBar(title: Text('$verificationLabel 본인인증')),
      body: SafeArea(
        top: false,
        child: Stack(
          children: [
            WebViewWidget(controller: _controller),
            if (_progress < 1)
              LinearProgressIndicator(value: _progress, minHeight: 2),
          ],
        ),
      ),
    );
  }
}
