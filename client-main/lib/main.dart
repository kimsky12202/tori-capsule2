import 'package:flutter/material.dart';
import 'ui/pages/login_page.dart';

void main() {
  runApp(const KMemoryCapsuleApp());
}

class KMemoryCapsuleApp extends StatelessWidget {
  const KMemoryCapsuleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Capsule',
      theme: ThemeData(
        // 빛바랜 한지/종이 배경색
        scaffoldBackgroundColor: const Color(0xFFF4F1EA), 
        primaryColor: const Color(0xFF2E2B2A), // 나전칠기함 연상시키는 색
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E2B2A)),
        fontFamily: 'Serif', 
      ),
      home: const LoginPage(),
    );
  }
}