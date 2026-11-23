import 'package:cam_board_client/board_controller.dart';
import 'package:cam_board_core/cam_board_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late FakeAdvertiser advertiser;
  late FakeServer server;
  late FakeNameStore store;
  String? lanAddress;

  BoardController build() => BoardController(
    advertiser: advertiser,
    server: server,
    nameStore: store,
    findAddress: () async => lanAddress,
  );

  setUp(() {
    advertiser = FakeAdvertiser();
    server = FakeServer();
    store = FakeNameStore();
    lanAddress = '192.168.43.1';
  });

  test('註冊成功：開始廣播、顯示位址、記住名字', () async {
    final controller = build();
    await controller.register(' 教室白板 ');

    expect(controller.state, BoardState.waiting);
    expect(controller.boardName, '教室白板');
    expect(controller.address, '192.168.43.1:47800');
    expect(controller.error, isNull);
    expect(advertiser.advertisedName, '教室白板');
    expect(advertiser.advertisedPort, 47800);
    expect(server.running, isTrue);
    expect(store.saved, '教室白板');
  });

  test('名字不合規定：不註冊，也不碰網路', () async {
    final controller = build();
    await controller.register('   ');

    expect(controller.state, BoardState.unregistered);
    expect(controller.error, isNotNull);
    expect(advertiser.isAdvertising, isFalse);
    expect(server.running, isFalse);
    expect(store.saved, isNull);
  });

  test('廣播失敗：退回未註冊，伺服器也要關掉', () async {
    advertiser.failOnStart = true;
    final controller = build();
    await controller.register('教室白板');

    expect(controller.state, BoardState.unregistered);
    expect(controller.error, isNotNull);
    expect(server.running, isFalse);
    expect(controller.busy, isFalse);
  });

  test('伺服器開不起來：退回未註冊，不會開始廣播', () async {
    server.failOnStart = true;
    final controller = build();
    await controller.register('教室白板');

    expect(controller.state, BoardState.unregistered);
    expect(controller.error, isNotNull);
    expect(advertiser.isAdvertising, isFalse);
  });

  test('失敗之後可以再註冊一次', () async {
    advertiser.failOnStart = true;
    final controller = build();
    await controller.register('教室白板');

    advertiser.failOnStart = false;
    await controller.register('教室白板');
    expect(controller.state, BoardState.waiting);
    expect(controller.error, isNull);
  });

  test('找不到區域網路位址：仍然註冊，位址是空的', () async {
    lanAddress = null;
    final controller = build();
    await controller.register('教室白板');

    expect(controller.state, BoardState.waiting);
    expect(controller.address, isNull);
  });

  test('撤銷註冊：停止廣播、關掉伺服器、回到未註冊', () async {
    final controller = build();
    await controller.register('教室白板');
    await controller.unregister();

    expect(controller.state, BoardState.unregistered);
    expect(controller.boardName, isNull);
    expect(controller.address, isNull);
    expect(advertiser.isAdvertising, isFalse);
    expect(server.running, isFalse);
  });

  test('已經註冊時再按註冊不會有作用', () async {
    final controller = build();
    await controller.register('第一個');
    await controller.register('第二個');
    expect(controller.boardName, '第一個');
  });

  test('讀得到上次存的名字', () async {
    store = FakeNameStore('上次的名字');
    expect(await build().loadSavedName(), '上次的名字');
  });
}
