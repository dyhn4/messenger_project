import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as socket_io;

import '../models/message.dart';
import '../models/room.dart';

/// room:read 브로드캐스트 한 건. 누가(userId) 언제(lastReadAt) 어느 방(roomId)을 읽었는지.
class RoomReadEvent {
  final String roomId;
  final String userId;
  final int lastReadAt;
  const RoomReadEvent({required this.roomId, required this.userId, required this.lastReadAt});

  factory RoomReadEvent.fromJson(Map<String, dynamic> json) => RoomReadEvent(
        roomId: json['roomId'] as String,
        userId: json['userId'] as String,
        lastReadAt: (json['lastReadAt'] as num).toInt(),
      );
}

/// Socket.io 연결을 감싸서 Message/Room/읽음 이벤트 스트림으로 노출합니다.
class ChatSocket {
  socket_io.Socket? _socket;
  final _messageController = StreamController<Message>.broadcast();
  final _roomController = StreamController<Room>.broadcast();
  final _readController = StreamController<RoomReadEvent>.broadcast();

  Stream<Message> get messages => _messageController.stream;

  /// 서버가 방 생성/합류를 알려줄 때(room:created) 흘러나온다. Session이 방 목록을 upsert하는 데 쓴다.
  Stream<Room> get roomEvents => _roomController.stream;

  /// 누군가 방을 읽었다는 브로드캐스트. 안읽음 카운터 갱신에 쓴다.
  Stream<RoomReadEvent> get readEvents => _readController.stream;
  bool get isConnected => _socket?.connected ?? false;

  void connect({required String baseUrl, required String token}) {
    _socket?.dispose();

    final socket = socket_io.io(
      baseUrl,
      socket_io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': token})
          .disableAutoConnect()
          .build(),
    );

    socket.on('message:new', (data) {
      _messageController.add(Message.fromJson(Map<String, dynamic>.from(data as Map)));
    });
    socket.on('room:created', (data) {
      _roomController.add(Room.fromJson(Map<String, dynamic>.from(data as Map)));
    });
    socket.on('room:read', (data) {
      _readController.add(RoomReadEvent.fromJson(Map<String, dynamic>.from(data as Map)));
    });

    socket.connect();
    _socket = socket;
  }

  void send({
    required String roomId,
    required String type,
    String? text,
    String? fileUrl,
    String? fileName,
    int? fileSize,
    String? mimeType,
  }) {
    _socket?.emit('message:send', {
      'roomId': roomId,
      'type': type,
      'text': ?text,
      'fileUrl': ?fileUrl,
      'fileName': ?fileName,
      'fileSize': ?fileSize,
      'mimeType': ?mimeType,
    });
  }

  void markRead(String roomId) {
    _socket?.emit('room:read', {'roomId': roomId});
  }

  void dispose() {
    _socket?.dispose();
    _socket = null;
  }
}
