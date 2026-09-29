/// 파싱 실패 타입. 소켓/DNS는 서버 고장이 아니라 기기 네트워크로 본다.
bool looksLikeNetworkParseFailure(Object? error) {
  final text = '$error'.toLowerCase();
  if (text.trim().isEmpty) return false;
  const markers = <String>[
    'failed host lookup',
    'socketexception',
    'clientexception',
    'network is unreachable',
    'network_unreachable',
    'no address associated',
    'nodename nor servname',
    'name or service not known',
    'connection refused',
    'connection reset',
    'connection closed',
    'software caused connection abort',
    'os error: 7',
    'errno = 7',
    'errno = 8',
  ];
  return markers.any(text.contains);
}

/// 새로 저장할 때. 백엔드가 준 구체 타입은 유지하고, 비었거나 server_error면 메시지에서 추론.
String resolvePersistedParseErrorType(
  Object? error, {
  String? providedType,
}) {
  final provided = (providedType ?? '').trim();
  if (provided.isNotEmpty && provided != 'server_error') return provided;
  if (looksLikeNetworkParseFailure(error)) return 'network_error';
  return provided.isEmpty ? 'server_error' : provided;
}

/// 이미 저장된 문서 표시용. 옛 server_error + 소켓 메시지도 네트워크로 보여 준다.
String resolveDisplayedParseErrorType({
  String? errorType,
  String? errorMessage,
}) {
  final provided = (errorType ?? '').trim();
  if (provided.isNotEmpty && provided != 'server_error') return provided;
  if (looksLikeNetworkParseFailure(errorMessage)) return 'network_error';
  return provided.isEmpty ? 'server_error' : provided;
}
