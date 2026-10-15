import 'package:flutter/material.dart';
import 'screens/login_screen.dart';
import 'screens/organiser_screen.dart';
import 'screens/student_screen.dart';

void main() {
  runApp(ProxyProofApp());
}

class ProxyProofApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ProxyProof',
      theme: ThemeData(primarySwatch: Colors.blue),
      initialRoute: '/',
      routes: {
        '/': (context) => LoginScreen(),
        '/organiser': (context) => OrganiserScreen(),
        '/student': (context) => StudentScreen(),
      },
    );
  }
}
