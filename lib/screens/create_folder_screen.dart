import 'package:flutter/material.dart';
import 'login_screen.dart';
import 'dashboard_screen.dart';
import '../services/folder_service.dart';
import '../services/auth_service.dart';

/// Create-folder screen, shared by two flows:
///
/// 1. Onboarding (`isOnboarding: true`) — the mandatory "create your first
///    family folder" step, reached via pushAndRemoveUntil right after
///    register/login when the user has zero folders yet. There is no
///    screen underneath this one on the stack, so:
///      - Cancel logs the user out and returns to Login.
///      - Done replaces the stack with the Dashboard.
///
/// 2. Add folder from the Dashboard (`isOnboarding: false`) — pushed on
///    top of the Dashboard, which already has a screen underneath it, so:
///      - Cancel just pops back to the Dashboard (no logout).
///      - Done pops back to the Dashboard. The Dashboard listens to
///        Firestore in real time (FolderService.streamUserFolders), so the
///        newly created folder appears in the folder list automatically —
///        no extra refresh call needed.
class CreateFolderScreen extends StatefulWidget {
  final bool isOnboarding;

  const CreateFolderScreen({super.key, this.isOnboarding = true});

  @override
  State<CreateFolderScreen> createState() => _CreateFolderScreenState();
}

class _CreateFolderScreenState extends State<CreateFolderScreen> {
  final _nameController = TextEditingController();
  int _selectedIconIndex = -1;
  bool _isSaving = false;

  // Grid order: Row 1 -> emoji1, emoji3, emoji5, emoji7
  //             Row 2 -> emoji2, emoji4, emoji6,
  final List<String> _icons = [
    'assets/emoji1.png',
    'assets/emoji3.png',
    'assets/emoji5.png',
    'assets/emoji7.png',
    'assets/emoji2.png',
    'assets/emoji4.png',
    'assets/emoji6.png',
  ];

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _handleSave() async {
    final name = _nameController.text.trim();

    if (name.isEmpty) {
      _showAlert('Missing Name', 'Please enter a family member name.');
      return;
    }
    if (_selectedIconIndex == -1) {
      _showAlert('Missing Icon', 'Please choose an icon for this folder.');
      return;
    }

    final selectedIcon = _icons[_selectedIconIndex];
    setState(() => _isSaving = true);

    final result = await FolderService.createFolder(
      folderName: name,
      folderIcon: selectedIcon,
    );

    if (!mounted) return;
    setState(() => _isSaving = false);

    if (!result.success) {
      _showAlert('Error', result.errorMessage ?? 'Failed to create folder.');
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.check_circle,
                color: Color(0xFFE8543D),
                size: 60,
              ),
              const SizedBox(height: 12),
              const Text(
                'Folder Created!',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                '"$name" folder has been created.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE8543D),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                  onPressed: () {
                    Navigator.pop(context); // close the success dialog
                    if (widget.isOnboarding) {
                      // No screen under this one yet — go to Dashboard and
                      // clear the stack so the back button can never
                      // return to Create Folder.
                      Navigator.pushAndRemoveUntil(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const DashboardScreen(),
                        ),
                        (route) => false,
                      );
                    } else {
                      // Dashboard is already underneath — just pop back to
                      // it. Its real-time folder stream will show the new
                      // folder without any extra refresh.
                      Navigator.pop(context);
                    }
                  },
                  child: const Text(
                    'Done',
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

  Future<void> _handleCancel() async {
    if (!widget.isOnboarding) {
      // Opened from the Dashboard's "add folder" tile — just go back to
      // it, no logout involved.
      Navigator.pop(context);
      return;
    }
    // Onboarding: this screen has no back stack (it replaced
    // login/register), so Cancel logs the user out and sends them back
    // to Login, rather than trying to "go back" to nothing.
    await AuthService.logout();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const LoginScreen()),
      (route) => false,
    );
  }

  void _showAlert(String title, String message) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                'OK',
                style: TextStyle(color: Color(0xFFE8543D)),
              ),
            ),
          ],
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
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(height: 16),

                  Image.asset('assets/logo.png', height: 200, width: 200),

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
                        Text(
                          widget.isOnboarding
                              ? 'Create Family Member Folder'
                              : 'Add Folder',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          widget.isOnboarding
                              ? 'Set up at least one folder to get started.'
                              : 'Add another family member folder.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[500],
                          ),
                        ),
                        const SizedBox(height: 16),

                        const Text(
                          'Family Member Name:',
                          style: TextStyle(fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _nameController,
                          decoration: InputDecoration(
                            hintText: 'Name',
                            filled: true,
                            fillColor: Colors.grey[100],
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide.none,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),

                        const Text(
                          'Choose Icon:',
                          style: TextStyle(fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 10),

                        // 2x4 icon grid
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _icons.length,
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 4,
                                mainAxisSpacing: 10,
                                crossAxisSpacing: 10,
                              ),
                          itemBuilder: (context, index) {
                            final isSelected = _selectedIconIndex == index;
                            return GestureDetector(
                              onTap: () {
                                setState(() {
                                  _selectedIconIndex = index;
                                });
                              },
                              child: Container(
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? const Color(
                                          0xFFE8543D,
                                        ).withOpacity(0.15)
                                      : Colors.grey[100],
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: isSelected
                                        ? const Color(0xFFE8543D)
                                        : Colors.transparent,
                                    width: 2,
                                  ),
                                ),
                                padding: const EdgeInsets.all(6),
                                child: Image.asset(_icons[index]),
                              ),
                            );
                          },
                        ),

                        const SizedBox(height: 24),

                        Row(
                          children: [
                            Expanded(
                              child: TextButton(
                                onPressed: _isSaving ? null : _handleCancel,
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                ),
                                child: Text(
                                  'Cancel',
                                  style: TextStyle(color: Colors.grey[600]),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: _isSaving ? null : _handleSave,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFFE8543D),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(30),
                                  ),
                                ),
                                child: _isSaving
                                    ? const SizedBox(
                                        height: 20,
                                        width: 20,
                                        child: CircularProgressIndicator(
                                          color: Colors.white,
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Text(
                                        'Save',
                                        style: TextStyle(
                                          fontSize: 16,
                                          color: Colors.white,
                                        ),
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
