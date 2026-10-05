// 웹 빌드용 — Windows 열기 대화상자·탐색기가 없다(folder_dialog.dart 참고). 공개 API 모양만 맞춘다.

class FilesOrFolder {
  final List<String> files;
  final String? folder;
  const FilesOrFolder.files(this.files) : folder = null;
  const FilesOrFolder.folder(String this.folder) : files = const [];
}

const folderPickPlaceholder = '폴더 선택';

Future<FilesOrFolder?> pickFilesOrFolder({String? title}) async => null;

Future<String?> openFolderInExplorer(String path) async =>
    'PC(Windows)에서 열 수 있는 경로입니다.';
