import 'package:flutter/material.dart';
import 'register_page.dart';
import 'main_page.dart';
import '../services/auth_api.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final AuthApi _authApi = AuthApi();
  bool _isLoading = false;
  bool _isResendingVerification = false;

  Future<void> _handleLogin() async {
    if (_emailController.text.isEmpty || _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('이메일과 비밀번호를 모두 입력해주세요. 📜')));
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      await _authApi.login(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );

      if (!mounted) {
        return;
      }

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const MainNavigationPage()),
      );
    } on AuthApiException catch (e) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('로그인 중 오류가 발생했습니다. 잠시 후 다시 시도해주세요.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _handleResendVerification() async {
    if (_emailController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('인증 메일을 받을 이메일을 먼저 입력해주세요.')),
      );
      return;
    }

    setState(() {
      _isResendingVerification = true;
    });

    try {
      await _authApi.requestVerification(email: _emailController.text.trim());

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('인증 메일을 다시 보냈습니다. 메일함을 확인해주세요.')),
      );
    } on AuthApiException catch (e) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('인증 메일 재발송 중 오류가 발생했습니다.')));
    } finally {
      if (mounted) {
        setState(() {
          _isResendingVerification = false;
        });
      }
    }
  }

  void _handleSocialLogin(String provider) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('🗝️ $provider(으)로 기억의 문을 엽니다.')));
    // 소셜 로그인 성공 시 main.dart에 있는 MainNavigationPage로 이동
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const MainNavigationPage()),
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const Color textColor = Color(0xFF2E2B2A);
    const Color textLightColor = Color(0xFF7A756D);
    const Color pointRedColor = Color(0xFFA14040);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 30),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 90,
                  height: 90,
                  decoration: BoxDecoration(
                    color: pointRedColor.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                    border: Border.all(color: pointRedColor, width: 2),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.lock_person_rounded,
                    size: 45,
                    color: pointRedColor,
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  '캡슐',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '특별한 순간의 감동을 다시 느껴보세요',
                  style: TextStyle(color: textLightColor, fontSize: 14),
                ),
                const SizedBox(height: 45),

                _buildTextField(
                  controller: _emailController,
                  icon: Icons.email_outlined,
                  hintText: '이메일',
                ),
                const SizedBox(height: 15),
                _buildTextField(
                  controller: _passwordController,
                  icon: Icons.key_outlined,
                  hintText: '비밀번호',
                  isPassword: true,
                ),
                const SizedBox(height: 35),

                SizedBox(
                  width: double.infinity,
                  height: 55,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: textColor,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 2,
                    ),
                    onPressed: _handleLogin,
                    child: _isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            '기록 꺼내보기',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              letterSpacing: 1.5,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _isResendingVerification
                        ? null
                        : _handleResendVerification,
                    child: Text(
                      _isResendingVerification
                          ? '인증 메일 보내는 중...'
                          : '인증 메일 다시 보내기',
                      style: const TextStyle(
                        color: pointRedColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 25),

                const Row(
                  children: [
                    Expanded(
                      child: Divider(thickness: 1, color: Color(0xFFD6D1C4)),
                    ),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 10),
                      child: Text(
                        '간편하게 열기',
                        style: TextStyle(color: textLightColor, fontSize: 12),
                      ),
                    ),
                    Expanded(
                      child: Divider(thickness: 1, color: Color(0xFFD6D1C4)),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                _buildSocialButton(
                  color: const Color(0xFFFEE500),
                  textColor: const Color(0xFF3C1E1E),
                  icon: Icons.chat_bubble,
                  text: '카카오로 시작하기',
                  onPressed: () => _handleSocialLogin('카카오'),
                ),
                const SizedBox(height: 12),

                _buildSocialButton(
                  color: Colors.white,
                  textColor: textColor,
                  icon: Icons.g_mobiledata,
                  iconColor: Colors.red,
                  text: 'Google로 시작하기',
                  isBordered: true,
                  onPressed: () => _handleSocialLogin('구글'),
                ),
                const SizedBox(height: 35),

                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      '아직 기록을 남기지 않으셨나요?',
                      style: TextStyle(color: textLightColor),
                    ),
                    TextButton(
                      // RegisterPage로 이동
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const RegisterPage(),
                        ),
                      ),
                      child: const Text(
                        '회원가입 시작하기',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: pointRedColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required IconData icon,
    required String hintText,
    bool isPassword = false,
  }) {
    return TextField(
      controller: controller,
      obscureText: isPassword,
      style: const TextStyle(color: Color(0xFF2E2B2A)),
      decoration: InputDecoration(
        prefixIcon: Icon(icon, color: const Color(0xFF7A756D)),
        hintText: hintText,
        hintStyle: const TextStyle(color: Color(0xFFA8A398)),
        filled: true,
        fillColor: const Color(0xFFFAF9F6),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE5E0D8)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE5E0D8)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF2E2B2A)),
        ),
      ),
    );
  }

  Widget _buildSocialButton({
    required Color color,
    required Color textColor,
    required IconData icon,
    Color? iconColor,
    required String text,
    bool isBordered = false,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: textColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          side: isBordered
              ? const BorderSide(color: Color(0xFFD6D1C4), width: 1)
              : BorderSide.none,
          elevation: isBordered ? 0 : 1,
        ),
        onPressed: onPressed,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon == Icons.g_mobiledata)
              Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Colors.red[50],
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: iconColor ?? textColor, size: 24),
              )
            else
              Icon(icon, size: 18, color: iconColor ?? textColor),
            const SizedBox(width: 10),
            Text(
              text,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }
}
