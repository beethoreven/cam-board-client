import 'package:flutter/material.dart';

void main() => runApp(const CamBoardApp());

/// 看板端。目前只有骨架，功能從「找到看板」這一步開始加。
class CamBoardApp extends StatelessWidget {
  const CamBoardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: '看板端',
      home: Scaffold(body: Center(child: Text('看板端'))),
    );
  }
}
