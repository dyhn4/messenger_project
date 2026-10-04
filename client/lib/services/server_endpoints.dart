/// 사내 주소와 외부(LTE/5G) 주소 사이에서 지금 연결되는 쪽을 고르는 규칙 — Session이 쓰고,
/// 네트워크 없이 테스트할 수 있게 여기 따로 둔다.
///
/// 주소들은 사용자가 입력하지 않는다: 서버 관리자가 서버 .env의 EXTERNAL_ADDRESS(설치형 서버는
/// 시작 메뉴 "외부 접속 주소")에 넣어두면, 앱이 접속했을 때 /server-info로 외부 주소와 사내
/// 주소들을 받아 저장해둔다. 그 뒤 지금 주소로 연결이 안 되면(소켓 연결 실패, 앱 복귀 시 점검)
/// 이 규칙대로 확인해서 되는 주소로 전환한다. 모든 주소가 같은 서버·같은 인증서라(서버가 외부
/// 주소와 사내 IP를 인증서에 넣어둠) 핀닝은 그대로 통한다.
library;

/// 서버가 알려준 주소를 저장할 형태로 정리한다(앞뒤 공백·끝 슬래시 제거). 비었으면 null.
String? normalizeServerUrl(String? url) {
  final trimmed = url?.trim().replaceAll(RegExp(r'/+$'), '');
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed;
}

/// 전환 후보 — 사내 주소가 앞, 외부 주소가 맨 뒤. 사용자가 사내 주소로 연결해뒀으면 그 주소,
/// 사내망 밖에서 외부 주소로 페어링했으면([primary]가 [external]과 같음) 서버가 알려준 사내
/// 주소들([internals])이 사내 쪽 후보다. 외부 주소가 없으면 전환할 일이 없으니 [primary]뿐.
List<String> endpointCandidates({
  required String primary,
  String? external,
  List<String> internals = const [],
}) {
  if (external == null) return [primary];
  if (primary != external) return [primary, external];
  return [...internals.where((u) => u != external), external];
}

/// 연결을 확인할 순서. 기본은 [candidates] 순서(사내 먼저) — 사내 와이파이에 돌아왔으면 외부
/// 주소(공유기를 한 바퀴 돌아오는 경로)보다 사내 주소를 쓰는 게 맞다. [currentFirst]면 지금 쓰던
/// 주소부터 본다 — 앱을 켤 때 지난번과 같은 네트워크일 가능성이 높아서, 밖에서 켤 때마다 사내
/// 주소 확인 시간만큼 늦게 뜨는 걸 피한다.
List<String> endpointProbeOrder(
  List<String> candidates, {
  String? current,
  bool currentFirst = false,
}) {
  final order = [...candidates];
  if (currentFirst && current != null && order.remove(current)) {
    order.insert(0, current);
  }
  return order;
}

/// [candidates]를 한꺼번에 [probe]하고, 순서상 가장 앞에서 연결되는 주소를 고른다(사내 IP가
/// 여러 개여도 하나씩 기다리지 않게 동시에 확인). 다 안 되면 null(오프라인 — 지금 주소를 그대로 둔다).
Future<String?> findReachableEndpoint(
  List<String> candidates,
  Future<bool> Function(String url) probe,
) async {
  final results = [for (final url in candidates) probe(url)];
  for (var i = 0; i < candidates.length; i++) {
    if (await results[i]) return candidates[i];
  }
  return null;
}
