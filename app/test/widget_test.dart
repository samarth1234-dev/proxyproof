import 'package:flutter_test/flutter_test.dart';
import 'package:proxyproof/main.dart';

void main() {
  testWidgets('ProxyProof smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const ProxyProofApp());
    expect(find.text('ProxyProof'), findsWidgets);
  });
}
