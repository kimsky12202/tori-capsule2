import 'package:flutter/material.dart';

// Main navigation screen shown after login.
class MainNavigationPage extends StatelessWidget {
  const MainNavigationPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F1EA),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF2E2B2A)),
      ),
      body: const Center(
        child: Text(
          '타임캡슐 메인 화면 (지도 및 추억 컬렉션)',
          style: TextStyle(color: Color(0xFF2E2B2A), fontSize: 16),
        ),
      ),
    );
  }
}