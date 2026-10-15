import 'package:flutter/material.dart';
import '../services/api_service.dart';

class LoginScreen extends StatefulWidget {
  @override
  _LoginScreenState createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _userController = TextEditingController();
  final _passController = TextEditingController();
  final _api = ApiService();

  void _handleLogin() async {
    final res = await _api.login(_userController.text, _passController.text);
    if (res.containsKey('token')) {
      await _api.saveToken(res['token']);
      Navigator.pushReplacementNamed(context, res['role'] == 'organiser' ? '/organiser' : '/student');
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Login Failed')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('ProxyProof Login')),
      body: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(controller: _userController, decoration: InputDecoration(labelText: 'Username')),
            TextField(controller: _passController, decoration: InputDecoration(labelText: 'Password'), obscureText: true),
            SizedBox(height: 20),
            ElevatedButton(onPressed: _handleLogin, child: Text('Login')),
          ],
        ),
      ),
    );
  }
}
