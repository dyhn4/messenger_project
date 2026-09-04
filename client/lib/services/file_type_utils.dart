/// 파일 경로만 보고 이미지인지 판단한다 — 드래그앤드롭으로 들어온 파일은 "어느 버튼으로
/// 골랐는지"(이미지 선택기 vs 파일 선택기) 신호가 없어서 확장자로 판별해야 한다. 여기 나열한
/// 확장자는 image_thumbnail.dart의 generateThumbnail(package:image)이 실제로 디코딩할 수 있는
/// 형식과 맞춰뒀다 — 오탐(이미지가 아닌데 true)이어도 썸네일 생성이 null을 돌려주며 안전하게
/// 파일 아이콘으로 대체되므로 문제없다.
bool looksLikeImagePath(String path) {
  final lower = path.toLowerCase();
  const extensions = ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'];
  return extensions.any((ext) => lower.endsWith(ext));
}
