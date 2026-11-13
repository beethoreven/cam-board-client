import 'package:cam_board_client/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('啟動後顯示「看板端」', (tester) async {
    await tester.pumpWidget(const CamBoardApp());
    expect(find.text('看板端'), findsOneWidget);
  });
}
