import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../services/account_service.dart';
import '../services/auth_service.dart';
import 'login_screen.dart';

/// Edit Profile
///   1. Account information (username + email, read-only)
///   2. Change password: old password, new password, confirm new password,
///      and a tick box that must be ticked before "Update Password" works
///   3. Danger zone: Delete Account (asks for the password + a tick box)
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  static const Color _accent = Color(0xFFE8543D);

  final _formKey = GlobalKey<FormState>();
  final _oldController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();
  final _deletePasswordController = TextEditingController();

  bool _obscureOld = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;

  bool _confirmChecked = false; // "I confirm I want to change my password"
  bool _busy = false;

  /// 0 = empty, 1 = weak, 2 = medium, 3 = strong (same scale as Register).
  int _strength = 0;

  String _username = '';
  String _email = '';

  @override
  void initState() {
    super.initState();
    _newController.addListener(_updateStrength);
    _loadProfile();
  }

  @override
  void dispose() {
    _newController.removeListener(_updateStrength);
    _oldController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    _deletePasswordController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final user = AuthService.currentUser;
    if (user == null) return;
    var username = '';
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      username = (doc.data()?['username'] as String?) ?? '';
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _email = user.email ?? '';
      _username = username;
    });
  }

  // ---------------- password rules (same as Register) ----------------

  static final RegExp _upper = RegExp(r'[A-Z]');
  static final RegExp _lower = RegExp(r'[a-z]');
  static final RegExp _number = RegExp(r'[0-9]');
  static final RegExp _special = RegExp(
    r'[!@#$%^&*(),.?":{}|<>_\-+=~`\[\]\\/;]',
  );

  void _updateStrength() {
    final v = _newController.text;
    int level;
    if (v.isEmpty) {
      level = 0;
    } else {
      var score = 0;
      if (_upper.hasMatch(v)) score++;
      if (_lower.hasMatch(v)) score++;
      if (_number.hasMatch(v)) score++;
      if (_special.hasMatch(v)) score++;
      if (v.length >= 8) score++;
      level = score <= 2 ? 1 : (score <= 4 ? 2 : 3);
    }
    if (level != _strength) setState(() => _strength = level);
  }

  Color _strengthColor() {
    switch (_strength) {
      case 1:
        return Colors.red[300]!;
      case 2:
        return Colors.orange[400]!;
      case 3:
        return Colors.green[500]!;
      default:
        return Colors.grey[300]!;
    }
  }

  String _strengthLabel() {
    switch (_strength) {
      case 1:
        return 'Weak';
      case 2:
        return 'Medium';
      case 3:
        return 'Strong';
      default:
        return '';
    }
  }

  String? _validateOld(String? value) {
    if (value == null || value.isEmpty) return 'Enter your old password';
    return null;
  }

  String? _validateNew(String? value) {
    if (value == null || value.isEmpty) return 'Enter a new password';
    if (value.length < 8) return 'Password must be at least 8 characters';
    if (!_upper.hasMatch(value) ||
        !_lower.hasMatch(value) ||
        !_number.hasMatch(value) ||
        !_special.hasMatch(value)) {
      return 'Must include upper, lower, number & special character';
    }
    if (value == _oldController.text) {
      return 'New password must be different from the old one';
    }
    return null;
  }

  String? _validateConfirm(String? value) {
    if (value == null || value.isEmpty) return 'Confirm your new password';
    if (value != _newController.text) return 'Passwords do not match';
    return null;
  }

  // ---------------- actions ----------------

  Future<void> _changePassword() async {
    if (_busy) return;
    if (!_formKey.currentState!.validate()) return;
    if (!_confirmChecked) {
      _showAlert('Please confirm', 'Tick the box to confirm the change.');
      return;
    }
    FocusScope.of(context).unfocus();

    setState(() => _busy = true);
    final result = await AccountService.changePassword(
      oldPassword: _oldController.text,
      newPassword: _newController.text,
    );
    if (!mounted) return;
    setState(() => _busy = false);

    if (!result.success) {
      _showAlert(
        'Could not change password',
        result.errorMessage ?? 'Please try again.',
      );
      return;
    }

    _oldController.clear();
    _newController.clear();
    _confirmController.clear();
    _formKey.currentState?.reset();
    setState(() => _confirmChecked = false);
    _showSuccess(
      'Password Updated!',
      'Use your new password the next time you log in.',
    );
  }

  Future<void> _confirmDeleteAccount() async {
    if (_busy) return;
    _deletePasswordController.clear();
    var understand = false;
    var obscure = true;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final canDelete =
                understand && _deletePasswordController.text.isNotEmpty;
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.red),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Delete account?',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'This permanently deletes your account, all family '
                      'folders, tasks and alarms. This cannot be undone.',
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _deletePasswordController,
                      obscureText: obscure,
                      onChanged: (_) => setDialogState(() {}),
                      decoration: _decoration(
                        'Enter your password to confirm',
                        suffix: IconButton(
                          icon: Icon(
                            obscure ? Icons.visibility_off : Icons.visibility,
                            color: Colors.grey,
                            size: 20,
                          ),
                          onPressed: () =>
                              setDialogState(() => obscure = !obscure),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    CheckboxListTile(
                      value: understand,
                      onChanged: (v) =>
                          setDialogState(() => understand = v ?? false),
                      activeColor: Colors.red,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text(
                        'I understand my data will be deleted forever.',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text(
                    'Cancel',
                    style: TextStyle(color: Colors.grey[700]),
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    disabledBackgroundColor: Colors.red.withOpacity(0.35),
                  ),
                  onPressed: canDelete
                      ? () => Navigator.pop(dialogContext, true)
                      : null,
                  child: const Text(
                    'Delete Account',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    final result = await AccountService.deleteAccount(
      password: _deletePasswordController.text,
    );
    _deletePasswordController.clear();
    if (!mounted) return;

    if (!result.success) {
      setState(() => _busy = false);
      _showAlert(
        'Could not delete account',
        result.errorMessage ?? 'Please try again.',
      );
      return;
    }

    // Account is gone -> back to Login, clearing the whole screen stack.
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
    messenger.showSnackBar(
      const SnackBar(content: Text('Your account has been deleted.')),
    );
  }

  // ---------------- dialogs ----------------

  void _showAlert(String title, String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK', style: TextStyle(color: _accent)),
          ),
        ],
      ),
    );
  }

  void _showSuccess(String title, String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, color: _accent, size: 60),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
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
                onPressed: () => Navigator.pop(context),
                child: const Text(
                  'Done',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- UI ----------------

  InputDecoration _decoration(String hint, {Widget? suffix}) {
    return InputDecoration(
      hintText: hint,
      filled: true,
      fillColor: Colors.grey[100],
      suffixIcon: suffix,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Colors.red),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Colors.red),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: const TextStyle(fontWeight: FontWeight.w500)),
  );

  Widget _passwordField({
    required TextEditingController controller,
    required String hint,
    required bool obscure,
    required VoidCallback onToggle,
    required String? Function(String?) validator,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      validator: validator,
      decoration: _decoration(
        hint,
        suffix: IconButton(
          icon: Icon(
            obscure ? Icons.visibility_off : Icons.visibility,
            color: Colors.grey,
            size: 20,
          ),
          onPressed: onToggle,
        ),
      ),
    );
  }

  Widget _card({required Widget child, Color? borderColor}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: borderColor == null ? null : Border.all(color: borderColor),
      ),
      child: child,
    );
  }

  Widget _buildAccountCard() {
    return _card(
      child: Row(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: _accent,
            child: Text(
              _username.isNotEmpty ? _username[0].toUpperCase() : 'U',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 22,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _username.isEmpty ? '—' : _username,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  _email.isEmpty ? '—' : _email,
                  style: TextStyle(color: Colors.grey[600], fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Text(
                  "Username and email can't be changed.",
                  style: TextStyle(color: Colors.grey[500], fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPasswordCard() {
    return _card(
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Change Password',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'Enter your old password, then choose a new one.',
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
            const SizedBox(height: 16),

            _label('Old Password:'),
            _passwordField(
              controller: _oldController,
              hint: 'Old password',
              obscure: _obscureOld,
              onToggle: () => setState(() => _obscureOld = !_obscureOld),
              validator: _validateOld,
            ),
            const SizedBox(height: 16),

            _label('New Password:'),
            _passwordField(
              controller: _newController,
              hint: 'New password',
              obscure: _obscureNew,
              onToggle: () => setState(() => _obscureNew = !_obscureNew),
              validator: _validateNew,
            ),
            if (_strength > 0) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: _strength / 3,
                        minHeight: 6,
                        backgroundColor: Colors.grey[200],
                        valueColor: AlwaysStoppedAnimation<Color>(
                          _strengthColor(),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _strengthLabel(),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _strengthColor(),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 6),
            Text(
              'At least 8 characters with upper, lower, number & special character.',
              style: TextStyle(fontSize: 11, color: Colors.grey[500]),
            ),
            const SizedBox(height: 16),

            _label('Confirm New Password:'),
            _passwordField(
              controller: _confirmController,
              hint: 'Confirm new password',
              obscure: _obscureConfirm,
              onToggle: () =>
                  setState(() => _obscureConfirm = !_obscureConfirm),
              validator: _validateConfirm,
            ),
            const SizedBox(height: 10),

            CheckboxListTile(
              value: _confirmChecked,
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _confirmChecked = v ?? false),
              activeColor: _accent,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text(
                'I confirm that I want to change my password.',
                style: TextStyle(fontSize: 13),
              ),
            ),
            const SizedBox(height: 8),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: (_confirmChecked && !_busy) ? _changePassword : null,
                icon: const Icon(Icons.lock_reset, color: Colors.white),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  disabledBackgroundColor: _accent.withOpacity(0.35),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                ),
                label: const Text(
                  'Update Password',
                  style: TextStyle(color: Colors.white, fontSize: 15),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeleteCard() {
    return _card(
      borderColor: Colors.red.withOpacity(0.4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.red, size: 20),
              SizedBox(width: 8),
              Text(
                'Delete Account',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.red,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Permanently remove your account together with all family folders, '
            'tasks and alarms. This cannot be undone.',
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _confirmDeleteAccount,
              icon: const Icon(Icons.delete_forever, color: Colors.red),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.red),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
              label: const Text(
                'Delete Account',
                style: TextStyle(color: Colors.red, fontSize: 15),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset('assets/bg.png', fit: BoxFit.cover),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const Text('Back', style: TextStyle(color: Colors.white)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Text(
                      'Edit Profile',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(left: 8, bottom: 16),
                    child: Text(
                      'Change your password or delete your account',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                  _buildAccountCard(),
                  const SizedBox(height: 16),
                  _buildPasswordCard(),
                  const SizedBox(height: 16),
                  _buildDeleteCard(),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
          if (_busy)
            Container(
              color: Colors.black26,
              child: const Center(
                child: CircularProgressIndicator(color: _accent),
              ),
            ),
        ],
      ),
    );
  }
}
