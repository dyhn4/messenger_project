import 'dart:io';

import 'package:client/models/todo.dart';
import 'package:client/services/folder_dialog.dart';
import 'package:client/services/todo_upload.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_todo_api.dart';

/// 할 일 파일 업로드(todo_upload.dart)와 "파일 또는 폴더" 대화상자(folder_dialog.dart)의 판단 부분 — 대화상자를 실제로
/// 띄우지 않고, 결과 경로 해석과 업로드 경로로의 복사(이름 겹침)를 시험한다.
void main() {
  group('파일 없이 [열기] = 폴더 고르기', () {
    test('이름 칸의 "폴더 선택"이 그대로 돌아오면 그 폴더 경로', () {
      final sep = Platform.pathSeparator;
      expect(
        folderFromPlaceholderPath('C:$sep자료$sep견적$sep$folderPickPlaceholder'),
        'C:$sep자료$sep견적',
      );
      // 드라이브 맨 위.
      expect(
        folderFromPlaceholderPath('C:$sep$folderPickPlaceholder'),
        'C:$sep',
      );
      // 공유 폴더.
      expect(
        folderFromPlaceholderPath(
          '$sep${sep}nas$sep공유$sep$folderPickPlaceholder',
        ),
        '$sep${sep}nas$sep공유',
      );
    });

    test('실제 파일을 골랐으면 폴더가 아니다', () {
      final sep = Platform.pathSeparator;
      expect(folderFromPlaceholderPath('C:$sep자료$sep견적.pdf'), isNull);
      expect(folderFromPlaceholderPath('폴더 선택'), isNull);
    });
  });

  group('업로드 경로로 복사', () {
    late Directory temp;
    setUp(() async {
      temp = await Directory.systemTemp.createTemp('todo_upload_test');
    });
    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('같은 이름이 있으면 "이름_보낸 사람.확장자", 그것도 있으면 번호를 붙여 복사한다', () async {
      final sep = Platform.pathSeparator;
      final source = Directory('${temp.path}${sep}src')..createSync();
      final target = Directory('${temp.path}${sep}dst')..createSync();
      final a = File('${source.path}$sep보고서.pdf')..writeAsStringSync('1');
      final b = File('${source.path}${sep}README')..writeAsStringSync('2');
      File('${target.path}$sep보고서.pdf').writeAsStringSync('old');

      final result = await copyFilesToFolder(
        [a, b],
        target.path,
        senderName: '홍길동',
      );
      expect(result.copied, 2);
      expect(result.failed, 0);
      expect(File('${target.path}$sep보고서_홍길동.pdf').readAsStringSync(), '1');
      // 겹치지 않으면 이름 그대로.
      expect(File('${target.path}${sep}README').readAsStringSync(), '2');
      // 원래 있던 파일은 그대로.
      expect(File('${target.path}$sep보고서.pdf').readAsStringSync(), 'old');

      // 같은 사람이 또 올리면 번호, 확장자 없는 파일은 이름 뒤에.
      await copyFilesToFolder([a, b], target.path, senderName: '홍길동');
      expect(File('${target.path}$sep보고서_홍길동 (1).pdf').readAsStringSync(), '1');
      expect(File('${target.path}${sep}README_홍길동').readAsStringSync(), '2');
    });

    test('보낸 사람 이름의 파일 이름으로 못 쓰는 글자는 _로, 이름이 없으면 번호만', () async {
      final sep = Platform.pathSeparator;
      File('${temp.path}$sep견적.xlsx').writeAsStringSync('old');
      expect(
        await uniqueTargetPath(temp.path, '견적.xlsx', '김/철:수'),
        '${temp.path}$sep견적_김_철_수.xlsx',
      );
      expect(
        await uniqueTargetPath(temp.path, '견적.xlsx', '  '),
        '${temp.path}$sep견적 (1).xlsx',
      );
    });

    test('없는 파일은 실패로 센다', () async {
      final sep = Platform.pathSeparator;
      final result = await copyFilesToFolder(
        [File('${temp.path}$sep없음.txt')],
        temp.path,
        senderName: '홍길동',
      );
      expect(result.copied, 0);
      expect(result.failed, 1);
    });
  });

  test('메시지로 보낼 때의 글 — 할 일 제목을 붙인다', () {
    final todo = Todo.fromJson(todoJson(title: '견적서 보내기'));
    expect(todoUploadCaption(todo), '[할 일] 견적서 보내기 — 파일을 올렸습니다.');
  });

  test('할 일 JSON의 빈 경로는 지정 안 함(null)', () {
    final todo = Todo.fromJson({
      ...todoJson(),
      'downloadPath': '  ',
      'uploadPath': r'\\nas\결과',
    });
    expect(todo.downloadPath, isNull);
    expect(todo.uploadPath, r'\\nas\결과');
  });
}
