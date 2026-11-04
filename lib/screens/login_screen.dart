import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'register_screen.dart';
import 'create_folder_screen.dart';
import 'dashboard_screen.dart';
import 'forgot_password_screen.dart';
import '../services/auth_service.dart';
import '../services/folder_service.dart';
import '../services/notification_scheduler.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const Color _accent = Color(0xFFE8543D);

  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _usernameFocusNode = FocusNode();

  bool _obscurePassword = true;
  bool _isProcessing = false;

  // Countdown shown while the account is locked out after too many
  // failed attempts (see AuthService.loginUser).
  int _lockoutSecondsRemaining = 0;
  int _lockoutTotalSeconds = 0;
  Timer? _lockoutTimer;

  @override
  void initState() {
    super.initState();
    _usernameFocusNode.addListener(() {
      if (!_usernameFocusNode.hasFocus) _checkUsernameLockout();
    });
  }

  Future<void> _checkUsernameLockout() async {
    final username = _usernameController.text.trim();
    if (username.isEmpty) return;
    final lock = await AuthService.checkLockoutStatus(username);
    if (!mounted || lock == null) return;
    _startLockoutCountdown(lock.lockoutSecondsRemaining);
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _usernameFocusNode.dispose();
    _lockoutTimer?.cancel();
    super.dispose();
  }

  void _startLockoutCountdown(int seconds) {
    _lockoutTimer?.cancel();
    setState(() {
      _lockoutSecondsRemaining = seconds;
      _lockoutTotalSeconds = seconds;
    });
    _lockoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _lockoutSecondsRemaining--;
        if (_lockoutSecondsRemaining <= 0) {
          _lockoutSecondsRemaining = 0;
          _lockoutTotalSeconds = 0;
          timer.cancel();
        }
      });
    });
  }

  String? _validateUsername(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Username is required';
    }
    return null;
  }

  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Password is required';
    }
    return null;
  }

  /// If a GUEST session was active and the login switched to a different
  /// account, the guest's alarms must not keep ringing on this phone.
  /// (The Dashboard re-arms the new account's alarms when it opens.)
  Future<void> _clearGuestAlarmsIfSwitched({
    required bool wasGuest,
    required String? previousUid,
  }) async {
    if (wasGuest && AuthService.currentUser?.uid != previousUid) {
      try {
        await NotificationScheduler.cancelAll();
      } catch (_) {}
    }
  }

  /// Opens the Dashboard (or first-time folder setup) and clears the whole
  /// back stack so Back can never return to Login / an old guest screen.
  void _openNext(bool hasFolder) {
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (context) => hasFolder
            ? const DashboardScreen()
            : const CreateFolderScreen(isOnboarding: true),
      ),
      (route) => false,
    );
  }

  Future<void> _handleLogin() async {
    if (_isProcessing) return; // security: block spam taps
    if (_lockoutSecondsRemaining > 0) return; // security: block during lockout
    if (!_formKey.currentState!.validate()) return;

    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    setState(() => _isProcessing = true);

    final wasGuest = AuthService.isGuest;
    final previousUid = AuthService.currentUser?.uid;

    final result = await AuthService.loginUser(username, password);
    if (!mounted) return;

    if (result.success) {
      await _clearGuestAlarmsIfSwitched(
        wasGuest: wasGuest,
        previousUid: previousUid,
      );
      final hasFolder = await FolderService.userHasFolders();
      if (!mounted) return;
      setState(() => _isProcessing = false);
      _showSuccessDialog(hasFolder);
    } else {
      setState(() => _isProcessing = false);
      if (result.isLocked) {
        _startLockoutCountdown(result.lockoutSecondsRemaining);
      }
      _showFailDialog(result.errorMessage ?? 'Login failed.');
    }
  }

  Future<void> _handleGoogleLogin() async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    final wasGuest = AuthService.isGuest;
    final previousUid = AuthService.currentUser?.uid;

    final result = await AuthService.signInWithGoogle();
    if (!mounted) return;

    if (result.success) {
      await _clearGuestAlarmsIfSwitched(
        wasGuest: wasGuest,
        previousUid: previousUid,
      );
      final hasFolder = await FolderService.userHasFolders();
      if (!mounted) return;
      setState(() => _isProcessing = false);
      _showSuccessDialog(hasFolder);
    } else {
      setState(() => _isProcessing = false);
      // Closing the Google account picker is not an error.
      if (!result.cancelled) {
        _showFailDialog(result.errorMessage ?? 'Google sign-in failed.');
      }
    }
  }

  /// "Use without login": starts a guest session and goes straight in
  /// (no success pop-up, so it is quick when your hands are busy).
  Future<void> _handleGuest() async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    final result = await AuthService.signInAsGuest();
    if (!mounted) return;

    if (!result.success) {
      setState(() => _isProcessing = false);
      _showFailDialog(result.errorMessage ?? 'Could not start guest mode.');
      return;
    }

    // Guests go straight to the Dashboard: no folder set-up (typing / icon
    // picking) is needed. Folders are created from the voice command itself.
    if (!mounted) return;
    setState(() => _isProcessing = false);
    _openNext(true);
  }

  void _showSuccessDialog(bool hasFolder) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle, color: _accent, size: 60),
              const SizedBox(height: 12),
              const Text(
                'Successful Login',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Welcome back to Fam-Assist!',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                  onPressed: () {
                    Navigator.pop(dialogContext);
                    _openNext(hasFolder);
                  },
                  child: const Text(
                    'Continue',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showFailDialog(String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error, color: _accent, size: 60),
              const SizedBox(height: 12),
              const Text(
                'Login Failed',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text(
                    'OK',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          image: DecorationImage(
            image: AssetImage('assets/bg.png'),
            fit: BoxFit.cover,
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(height: 16),

                    Image.asset('assets/logo.png', height: 200, width: 200),

                    const Text(
                      'Welcome Back!',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),

                    const SizedBox(height: 16),

                    // White card container
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildLabel('Username:'),
                          _buildTextField(
                            _usernameController,
                            'username',
                            focusNode: _usernameFocusNode,
                            validator: _validateUsername,
                            keyboardType: TextInputType.text,
                          ),
                          const SizedBox(height: 16),

                          _buildLabel('Password:'),
                          _buildTextField(
                            _passwordController,
                            'password',
                            obscureText: _obscurePassword,
                            validator: _validatePassword,
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscurePassword
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                                color: Colors.grey,
                              ),
                              onPressed: () {
                                setState(
                                  () => _obscurePassword = !_obscurePassword,
                                );
                              },
                            ),
                          ),

                          // Forgot password: right-aligned, directly under
                          // the password box
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: _isProcessing
                                  ? null
                                  : () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              const ForgotPasswordScreen(),
                                        ),
                                      );
                                    },
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                minimumSize: const Size(0, 32),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: const Text(
                                'Forgot Password?',
                                style: TextStyle(
                                  color: _accent,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),

                          const SizedBox(height: 4),

                          // Login button
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed:
                                  (_isProcessing ||
                                      _lockoutSecondsRemaining > 0)
                                  ? null
                                  : _handleLogin,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _accent,
                                disabledBackgroundColor: Colors.grey[400],
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(30),
                                ),
                              ),
                              child: _isProcessing
                                  ? const SizedBox(
                                      height: 20,
                                      width: 20,
                                      child: CircularProgressIndicator(
                                        color: Colors.white,
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Text(
                                      _lockoutSecondsRemaining > 0
                                          ? 'Try again in ${_lockoutSecondsRemaining}s'
                                          : 'Login',
                                      style: const TextStyle(
                                        fontSize: 16,
                                        color: Colors.white,
                                      ),
                                    ),
                            ),
                          ),
                          if (_lockoutSecondsRemaining > 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: _buildLockoutBanner(),
                            ),

                          const SizedBox(height: 10),

                          // Divider with "or" (tight spacing)
                          Row(
                            children: [
                              Expanded(
                                child: Divider(
                                  color: Colors.grey[300],
                                  thickness: 1,
                                  height: 1,
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                child: Text(
                                  'or',
                                  style: TextStyle(
                                    color: Colors.grey[500],
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Divider(
                                  color: Colors.grey[300],
                                  thickness: 1,
                                  height: 1,
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 10),

                          // Google sign-in
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: _isProcessing
                                  ? null
                                  : _handleGoogleLogin,
                              icon: const GoogleLogo(size: 20),
                              label: const Text(
                                'Continue with Google',
                                style: TextStyle(
                                  color: Colors.black87,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                side: BorderSide(color: Colors.grey.shade300),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(30),
                                ),
                              ),
                            ),
                          ),

                          const SizedBox(height: 10),

                          // Guest mode: use the voice reminder without login
                          SizedBox(
                            width: double.infinity,
                            child: TextButton.icon(
                              onPressed: _isProcessing ? null : _handleGuest,
                              icon: const Icon(
                                Icons.mic_none,
                                color: _accent,
                                size: 20,
                              ),
                              label: const Text(
                                'Use without login',
                                style: TextStyle(
                                  color: _accent,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              style: TextButton.styleFrom(
                                backgroundColor: _accent.withOpacity(0.08),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(30),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Center(
                            child: Text(
                              'Record voice reminders right away. Create an '
                              'account later to keep them safe.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.grey[500],
                                fontSize: 11,
                              ),
                            ),
                          ),

                          const SizedBox(height: 8),

                          // Register link: one tidy line
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                "Don't have an account?",
                                style: TextStyle(
                                  color: Colors.grey[600],
                                  fontSize: 13,
                                ),
                              ),
                              TextButton(
                                onPressed: _isProcessing
                                    ? null
                                    : () {
                                        Navigator.pushReplacement(
                                          context,
                                          MaterialPageRoute(
                                            builder: (context) =>
                                                const RegisterScreen(),
                                          ),
                                        );
                                      },
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                  ),
                                  minimumSize: const Size(0, 32),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                child: const Text(
                                  'Register',
                                  style: TextStyle(
                                    color: _accent,
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLockoutBanner() {
    final progress = _lockoutTotalSeconds == 0
        ? 0.0
        : _lockoutSecondsRemaining / _lockoutTotalSeconds;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red[50],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red[100]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lock_clock, color: Colors.red[400], size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Too many failed attempts',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.red[700],
                  ),
                ),
              ),
              Text(
                '${_lockoutSecondsRemaining}s',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.red[700],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: Colors.red[100],
              valueColor: AlwaysStoppedAnimation<Color>(Colors.red[400]!),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.w500)),
    );
  }

  Widget _buildTextField(
    TextEditingController controller,
    String hint, {
    bool obscureText = false,
    String? Function(String?)? validator,
    TextInputType keyboardType = TextInputType.text,
    Widget? suffixIcon,
    FocusNode? focusNode,
  }) {
    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      obscureText: obscureText,
      validator: validator,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: Colors.grey[100],
        suffixIcon: suffixIcon,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Colors.red),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
      ),
    );
  }
}

/// Four-colour Google "G" logo, drawn with code (no image file needed).
class GoogleLogo extends StatelessWidget {
  final double size;
  const GoogleLogo({super.key, this.size = 20});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _GoogleLogoPainter()),
    );
  }
}

class _GoogleLogoPainter extends CustomPainter {
  static const Color _blue = Color(0xFF4285F4);
  static const Color _red = Color(0xFFEA4335);
  static const Color _yellow = Color(0xFFFBBC05);
  static const Color _green = Color(0xFF34A853);

  double _rad(double deg) => deg * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.2;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - stroke / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    Paint paintOf(Color c) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;

    // Red (top), Blue (right-lower), Green (bottom), Yellow (left)
    canvas.drawArc(rect, _rad(-135), _rad(90), false, paintOf(_red));
    canvas.drawArc(rect, _rad(0), _rad(45), false, paintOf(_blue));
    canvas.drawArc(rect, _rad(45), _rad(90), false, paintOf(_green));
    canvas.drawArc(rect, _rad(135), _rad(90), false, paintOf(_yellow));

    // Blue horizontal bar of the "G"
    final bar = Rect.fromLTRB(
      center.dx,
      center.dy - stroke / 2,
      size.width,
      center.dy + stroke / 2,
    );
    canvas.drawRect(bar, Paint()..color = _blue);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
