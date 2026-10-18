import 'dart:async';

import 'package:flutter/material.dart';

import '../models/room.dart';
import '../services/api_client.dart' show ApiException;
import '../services/session.dart';
import '../widgets/floating_dialog.dart';
import '../widgets/muted_scrollbar.dart';
import 'home_screen.dart' show wideBreakpoint;
import 'invite_members_screen.dart';
import '../l10n/tr.dart';

/// 새로운 토픽 생성하기 — 넓은 화면(PC)은 떠 있는 창, 좁은 화면(모바일)은 전체 화면으로 띄우고,
/// 만들어지면 [onOpenRoom]으로 그 토픽을 연 뒤 바로 "멤버 초대하기"를 띄운다(만든 사람만 멤버라서).
/// [initialFolderId]를 주면 그 폴더를 미리 골라 둔다. 사이드바·모바일 목록·참여 가능한 토픽 보기가
/// 같이 쓰는 진입점.
Future<Room?> showCreateTopicFlow(
  BuildContext context,
  Session session, {
  required void Function(Room) onOpenRoom,
  String? initialFolderId,
}) async {
  final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
  final navigator = Navigator.of(context);
  final room = wide
      ? await showDialog<Room>(
          context: context,
          builder: (_) => CreateTopicScreen(
            session: session,
            asDialog: true,
            initialFolderId: initialFolderId,
          ),
        )
      : await navigator.push<Room>(
          MaterialPageRoute(
            builder: (_) => CreateTopicScreen(
              session: session,
              initialFolderId: initialFolderId,
            ),
          ),
        );
  if (room == null) return null;
  onOpenRoom(room);
  // onOpenRoom이 이 흐름을 부른 화면(참여 가능한 토픽 보기 등)을 닫았을 수 있어서, 그때는
  // 앱 전체 Navigator 기준으로 초대 창을 띄운다. 초대 창이 닫히길 기다리지는 않는다.
  if (navigator.mounted) {
    unawaited(
      showInviteMembers(
        context.mounted ? context : navigator.context,
        session,
        room,
      ),
    );
  }
  return room;
}

class CreateTopicScreen extends StatefulWidget {
  final Session session;
  final bool asDialog;

  /// 미리 골라 둘 내 토픽 폴더(폴더 머리의 "+" 등에서 열었을 때).
  final String? initialFolderId;
  const CreateTopicScreen({
    super.key,
    required this.session,
    this.asDialog = false,
    this.initialFolderId,
  });

  @override
  State<CreateTopicScreen> createState() => _CreateTopicScreenState();
}

/// 폴더 드롭다운의 "폴더 없음" — 실제 폴더 id와 겹치지 않는 값.
const _noFolder = '';

class _CreateTopicScreenState extends State<CreateTopicScreen> {
  final _name = TextEditingController();
  final _nameFocus = FocusNode();
  final _description = TextEditingController();
  final _scroll = ScrollController();

  TopicViewMode _viewMode = TopicViewMode.chat;
  bool _isPublic = true;
  bool _autoInvite = false;
  bool _readOnly = false;
  late String _folderId = widget.initialFolderId ?? _noFolder;

  bool _submitting = false;
  String? _nameError;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _nameFocus.dispose();
    _description.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 고른 폴더가 (다른 기기에서) 지워졌으면 "폴더 없음"으로 본다.
  String get _effectiveFolderId =>
      widget.session.topicFolders.any((f) => f.id == _folderId)
      ? _folderId
      : _noFolder;

  Future<void> _submit() async {
    if (_submitting) return;
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = tr('토픽 이름을 입력하세요.'));
      _nameFocus.requestFocus();
      return;
    }
    final folderId = _effectiveFolderId;
    setState(() {
      _submitting = true;
      _nameError = null;
      _error = null;
    });
    try {
      final room = await widget.session.createTopic(
        name: name,
        description: _description.text.trim(),
        isPublic: _isPublic,
        viewMode: _viewMode,
        readOnly: _readOnly,
        // 비공개 토픽은 자동 초대를 쓸 수 없다.
        autoInvite: _isPublic && _autoInvite,
        folderId: folderId == _noFolder ? null : folderId,
      );
      if (!mounted) return;
      Navigator.of(context).pop(room);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        // 서버가 준 안내(권한 없음 등)는 그대로, 그 밖의 오류는 풀어서 보여준다.
        _error = e is ApiException
            ? e.message
            : tr('토픽을 만들지 못했습니다. 잠시 후 다시 시도하세요.');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 만드는 요청이 가는 동안은 Esc·뒤로 가기·바깥 누르기로 닫히지 않게 한다(취소 버튼도 잠겨
    // 있다) — 닫혀 버리면 토픽은 만들어지는데 그 토픽을 열고 멤버 초대하기를 띄우는 흐름이 빠진다.
    return PopScope(canPop: !_submitting, child: _buildScreen(context));
  }

  Widget _buildScreen(BuildContext context) {
    final form = _buildForm(context);
    final actions = Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        const SizedBox(width: 8),
        FilledButton(
          key: const ValueKey('create-topic-submit'),
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(tr('생성')),
        ),
      ],
    );

    if (widget.asDialog) {
      return FloatingDialog(
        title: tr('새로운 토픽 생성하기'),
        maxWidth: 600,
        maxHeight: 820,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: MutedScrollbar(
                controller: _scroll,
                child: SingleChildScrollView(
                  controller: _scroll,
                  // 스크롤바(10px)가 입력칸·스위치를 덮지 않게 오른쪽을 비운다.
                  padding: const EdgeInsets.only(right: 16),
                  child: form,
                ),
              ),
            ),
            const SizedBox(height: 16),
            actions,
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(tr('새로운 토픽 생성하기'))),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: form,
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: actions,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildForm(BuildContext context) {
    final theme = Theme.of(context);
    final small = TextStyle(fontSize: 12, color: theme.hintColor);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Label(tr('이름')),
        TextField(
          key: const ValueKey('create-topic-name'),
          controller: _name,
          focusNode: _nameFocus,
          autofocus: true,
          maxLength: topicNameMaxLength,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            hintText: tr('토픽 이름을 입력하세요'),
            border: const OutlineInputBorder(),
            isDense: true,
            errorText: _nameError,
          ),
          onChanged: (_) {
            if (_nameError != null) setState(() => _nameError = null);
          },
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 8),
        _Label(tr('보기 방식')),
        LayoutBuilder(
          builder: (context, constraints) {
            final cards = [
              for (final mode in TopicViewMode.values)
                _ChoiceCard(
                  key: ValueKey('create-topic-view-${mode.wire}'),
                  icon: mode == TopicViewMode.board
                      ? Icons.dashboard_outlined
                      : Icons.chat_bubble_outline,
                  title: mode.label,
                  description: mode.description,
                  selected: _viewMode == mode,
                  onTap: _submitting
                      ? null
                      : () => setState(() => _viewMode = mode),
                ),
            ];
            // 좁은 화면(모바일)에서는 설명이 몇 글자씩 끊기지 않게 위아래로 쌓는다.
            if (constraints.maxWidth < 440) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [cards[0], const SizedBox(height: 8), cards[1]],
              );
            }
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: cards[0]),
                  const SizedBox(width: 12),
                  Expanded(child: cards[1]),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Icon(Icons.info_outline, size: 14, color: theme.hintColor),
            const SizedBox(width: 4),
            Expanded(child: Text(tr('보기 방식은 만든 뒤에 바꿀 수 없습니다.'), style: small)),
          ],
        ),
        const SizedBox(height: 18),
        _Label(tr('공개 여부')),
        RadioGroup<bool>(
          groupValue: _isPublic,
          onChanged: (v) {
            if (_submitting || v == null) return;
            setState(() => _isPublic = v);
          },
          child: const Column(
            children: [
              TopicVisibilityTile(
                key: ValueKey('create-topic-public'),
                isPublic: true,
              ),
              TopicVisibilityTile(
                key: ValueKey('create-topic-private'),
                isPublic: false,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _Label(tr('토픽 설명'), optional: true),
        TextField(
          key: const ValueKey('create-topic-description'),
          controller: _description,
          maxLength: topicDescriptionMaxLength,
          minLines: 2,
          maxLines: 4,
          decoration: InputDecoration(
            hintText: tr('어떤 이야기를 나누는 토픽인지 적어 주세요'),
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 10),
        _Label(tr('폴더 선택'), optional: true),
        // 폴더가 다른 기기에서 생기거나 지워지면 바로 따라가도록 이 칸만 세션 변경을 듣는다.
        ListenableBuilder(
          listenable: widget.session,
          builder: (context, _) => _buildFolderPicker(context),
        ),
        const SizedBox(height: 10),
        SwitchListTile(
          key: const ValueKey('create-topic-auto-invite'),
          contentPadding: EdgeInsets.zero,
          value: _isPublic && _autoInvite,
          onChanged: _isPublic && !_submitting
              ? (v) => setState(() => _autoInvite = v)
              : null,
          title: Text(tr('정회원 자동 초대')),
          subtitle: Text(
            _isPublic
                ? tr('새로 팀에 들어오는 정회원을 이 토픽에 자동으로 초대합니다')
                : tr('비공개 토픽은 자동 초대를 쓸 수 없습니다'),
            style: small,
          ),
        ),
        SwitchListTile(
          key: const ValueKey('create-topic-read-only'),
          contentPadding: EdgeInsets.zero,
          value: _readOnly,
          onChanged: _submitting ? null : (v) => setState(() => _readOnly = v),
          title: Text(tr('읽기 전용 설정')),
          subtitle: Text(tr('토픽 관리자만 글을 쓸 수 있고, 다른 멤버는 읽기만 합니다'), style: small),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Container(
            key: const ValueKey('create-topic-error'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 18,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _error!,
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildFolderPicker(BuildContext context) {
    final theme = Theme.of(context);
    final folders = widget.session.topicFolders;
    return InputDecorator(
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: const ValueKey('create-topic-folder'),
          value: _effectiveFolderId,
          isExpanded: true,
          borderRadius: BorderRadius.circular(8),
          icon: const Icon(Icons.keyboard_arrow_down, size: 20),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurface,
          ),
          items: [
            DropdownMenuItem(value: _noFolder, child: Text(tr('폴더 없음'))),
            for (final f in folders)
              DropdownMenuItem(
                value: f.id,
                child: Row(
                  children: [
                    Icon(
                      Icons.folder_outlined,
                      size: 18,
                      color: theme.hintColor,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(f.name, overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
          ],
          onChanged: _submitting
              ? null
              : (v) => setState(() => _folderId = v ?? _noFolder),
        ),
      ),
    );
  }
}

/// 공개 여부 라디오 한 줄(공개 / 비공개) — 새 토픽 만들기와 토픽 정보 변경하기가 같이 쓴다.
/// 위에 `RadioGroup<bool>`이 있어야 한다.
class TopicVisibilityTile extends StatelessWidget {
  final bool isPublic;
  const TopicVisibilityTile({super.key, required this.isPublic});

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return RadioListTile<bool>(
      contentPadding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      value: isPublic,
      title: Row(
        children: [
          Text(isPublic ? tr('공개') : tr('비공개')),
          const SizedBox(width: 6),
          Icon(isPublic ? Icons.public : Icons.lock_outline, size: 16),
        ],
      ),
      subtitle: Text(
        isPublic ? tr('정회원이면 누구나 찾아서 참여할 수 있어요') : tr('초대받은 멤버만 참여할 수 있어요'),
        style: TextStyle(fontSize: 12, color: hint),
      ),
    );
  }
}

/// 굵은 항목 이름 — [optional]이면 옆에 회색 "(선택)".
class _Label extends StatelessWidget {
  final String text;
  final bool optional;
  const _Label(this.text, {this.optional = false});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: text,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          if (optional)
            TextSpan(
              text: tr('  (선택)'),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).hintColor,
              ),
            ),
        ],
      ),
    ),
  );
}

/// 보기 방식 고르기 카드 — 고른 카드는 강조색 테두리·옅은 바탕·체크 표시.
class _ChoiceCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final bool selected;
  final VoidCallback? onTap;
  const _ChoiceCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radius = BorderRadius.circular(10);
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.06)
            : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: selected ? scheme.primary : theme.dividerColor,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 12),
            // 설명은 카드 폭 전체를 쓰게 아이콘·제목 줄 아래에 둔다(좁은 카드에서 글자가
            // 한두 자씩 끊기지 않게).
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: selected
                            ? scheme.primary.withValues(alpha: 0.12)
                            : scheme.surfaceContainerHighest,
                      ),
                      child: Icon(
                        icon,
                        size: 18,
                        color: selected
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: selected ? scheme.primary : null,
                        ),
                      ),
                    ),
                    Icon(
                      selected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      size: 20,
                      color: selected ? scheme.primary : theme.dividerColor,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  description,
                  style: TextStyle(fontSize: 12, color: theme.hintColor),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
