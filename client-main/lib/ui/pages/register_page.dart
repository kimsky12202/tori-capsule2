import 'package:flutter/material.dart';
import '../services/auth_api.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _passwordConfirmController =
      TextEditingController();
  final TextEditingController _nicknameController = TextEditingController();
  final AuthApi _authApi = AuthApi();
  bool _isLoading = false;

  Future<void> _handleRegister() async {
    if (_emailController.text.isEmpty ||
        _passwordController.text.isEmpty ||
        _passwordConfirmController.text.isEmpty ||
        _nicknameController.text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('모든 항목을 입력해주세요.')));
      return;
    }

    if (_passwordController.text.length < 8) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('비밀번호는 8자리 이상이어야 합니다.')));
      return;
    }

    if (_passwordController.text != _passwordConfirmController.text) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('비밀번호와 비밀번호 확인이 일치하지 않습니다.')),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      await _authApi.register(
        email: _emailController.text.trim(),
        username: _nicknameController.text.trim(),
        password: _passwordController.text,
        passwordConfirm: _passwordConfirmController.text,
      );

      if (!mounted) {
        return;
      }

      _showSnackBar('회원가입이 완료되었습니다. 이메일 인증 후 로그인해주세요.');
      Navigator.pop(context);
    } on AuthApiException catch (e) {
      if (!mounted) {
        return;
      }

      _showSnackBar(e.message);
    } catch (_) {
      if (!mounted) {
        return;
      }

      _showSnackBar('오류가 발생했습니다. 잠시 후 다시 시도해주세요.');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _passwordConfirmController.dispose();
    _nicknameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const Color textColor = Color(0xFF2E2B2A);
    const Color textLightColor = Color(0xFF7A756D);
    const Color pointRedColor = Color(0xFFA14040);

    return Scaffold(
      backgroundColor: const Color(0xFFF4F1EA),
      appBar: AppBar(
        title: const Text(
          '기록자 등록',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
        ),
        backgroundColor: Colors.transparent,
        foregroundColor: textColor,
        elevation: 0,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(30),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '환영합니다',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '미래의 나에게 남길 소중한 생각을 적어주세요.',
                style: TextStyle(color: textLightColor, height: 1.5),
              ),
              const SizedBox(height: 40),

              _buildLabel('여행자 이름 (닉네임)'),
              _buildTextField(
                controller: _nicknameController,
                icon: Icons.person_outline,
                hintText: '사용할 닉네임',
              ),
              const SizedBox(height: 20),

              _buildLabel('이메일'),
              _buildTextField(
                controller: _emailController,
                icon: Icons.email_outlined,
                hintText: 'example@gmail.com',
              ),
              const SizedBox(height: 20),

              _buildLabel('비밀번호'),
              _buildTextField(
                controller: _passwordController,
                icon: Icons.vpn_key_outlined,
                hintText: '8자리 이상 입력',
                isPassword: true,
              ),
              const SizedBox(height: 20),

              _buildLabel('비밀번호 확인'),
              _buildTextField(
                controller: _passwordConfirmController,
                icon: Icons.verified_user_outlined,
                hintText: '비밀번호를 다시 입력',
                isPassword: true,
              ),
              const SizedBox(height: 50),

              SizedBox(
                width: double.infinity,
                height: 55,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: pointRedColor,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 2,
                  ),
                  onPressed: _handleRegister,
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
                          '회원가입 완료하기',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            letterSpacing: 1.0,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 20),
              ],
            ),
          ),
        ),
    );
  }

  Widget _buildLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: Color(0xFF2E2B2A),
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
}
