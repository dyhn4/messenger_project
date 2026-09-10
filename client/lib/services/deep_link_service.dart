import 'package:app_links/app_links.dart';

/// 초대 링크(`tangotalk://pair?address=...&code=...`)에서 뽑아낸 서버 주소/코드.
/// [ServerSetupScreen]과 로그인 화면의 "서버 주소 변경" 다이얼로그가 이 값으로
/// 입력칸을 미리 채운다(자동 연결까지는 하지 않음 — 사용자가 직접 확인 후 눌러야 함).
class PairRequest {
  final String address;
  final String code;
  const PairRequest({required this.address, required this.code});
}

/// 앱이 딥링크(tangotalk:// 커스텀 스킴)로 열렸을 때를 감지한다. Android는 인텐트로,
/// Windows는 명령줄 인자(app_links의 SendAppLinkToInstance가 이미 떠 있는 창에도
/// 전달해준다)로 전달된다 — 둘 다 app_links 패키지 하나로 같이 처리된다.
class DeepLinkService {
  final _appLinks = AppLinks();

  PairRequest? _parse(Uri uri) {
    if (uri.scheme != 'tangotalk') return null;
    final address = uri.queryParameters['address'];
    final code = uri.queryParameters['code'];
    if (address == null || address.isEmpty || code == null || code.isEmpty) {
      return null;
    }
    return PairRequest(address: address, code: code);
  }

  /// 앱이 딥링크로 막 켜졌을 때(콜드 스타트)의 링크. 링크 없이 켜졌으면 null.
  Future<PairRequest?> getInitialPairRequest() async {
    final uri = await _appLinks.getInitialLink();
    return uri == null ? null : _parse(uri);
  }

  /// 앱이 이미 떠 있는 동안 새 링크가 들어온 경우(Windows는 SendAppLinkToInstance로
  /// 전달된 경우 포함).
  Stream<PairRequest> get pairRequestStream =>
      _appLinks.uriLinkStream.map(_parse).where((r) => r != null).cast();
}
